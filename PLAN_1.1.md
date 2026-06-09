# Peek 1.1 — implementation plan

**Branch:** `feature/1.1` (off `main`, which now holds shipped 1.0 build 4 + docs).
**Scope (agreed):** #11 multi-display capture · #7 menu/icon polish · #9 live Claude Desktop smoke.
**Status:** plan-for-review. No code written yet.

---

## 0. RESOLVED — `allowScreenCapture` semantics

**Decision (confirmed):** Option B tri-state, **and** the per-display approval prompt
always fires on first capture even when policy allows. So `evaluateDisplayCapture()`
returns only `.denied` (managed `false`) vs `.userControlled` (absent **or** managed
`true`) — `.allowed` is never returned, because we always want the gate-2 prompt for the
wider-surface display capture. Detail below.

---

## 0-orig. The fork (for context) — `allowScreenCapture` semantics

`ManagedPreferences.allowScreenCapture` today is `bool("allowScreenCapture") ?? false`.
For an **unmanaged** user (no `/Library/Managed Preferences` plist — i.e. every App Store
customer) that resolves to `false`. TODO #11 says "capture_display must return a
policy-denied error" when false → **the headline feature would be off for everyone.**

**Recommended (Option B):** make it tri-state like `allowedApps`/`deniedApps` already are.

| Managed plist state | `capture_display` behaviour |
|---|---|
| key absent (unmanaged user) | **user-controlled** → per-display approval prompt decides |
| `allowScreenCapture = true` | allowed → per-display prompt still applies (or auto-allow; see §3) |
| `allowScreenCapture = false` | hard policy-deny (managed fleet opted out) |

`list_displays` stays allowed in all three states (it leaks geometry + monitor names,
not pixels) — matching how `list_windows` filters but never hard-blocks enumeration.

Implementation: add `ManagedPreferences.evaluateDisplayCapture() -> AppPolicyDecision`
mirroring `evaluate(bundleID:appName:)`. Keep the existing `allowScreenCapture` Bool but
stop using it as the gate; the gate becomes the new tri-state evaluator.

**→ Need your confirmation on Option B before I build §3.** (Alternative A = ship it
admin-opt-in only, which I don't recommend for a consumer feature.)

---

## 1. New file: `peek/DisplayCapture.swift`

Parallel to `WindowCapture` — keep `WindowCapture` named as-is (renaming to `Capture`
per the old TODO note would churn MCPTools, PeekApp, and tests for no gain).

```
struct DisplayInfo: Sendable, Hashable {
    let id: CGDirectDisplayID
    let name: String        // NSScreen.localizedName, correlated by NSScreenNumber
    let frame: CGRect
    let isMain: Bool
}

enum DisplayCapture {
    static func listDisplays() async throws -> [DisplayInfo]
    static func resolveDisplay(id: CGDirectDisplayID) async throws -> DisplayInfo
    static func resolveDisplay(name: String) async throws -> DisplayInfo   // case-insensitive substring; throws on ambiguous
    static func captureDisplay(id: CGDirectDisplayID) async throws -> Data
}
```

Details:
- Source displays from `SCShareableContent.current.displays` (reuse the existing
  `fetchContent`-style permission→`WindowCaptureError.permissionDenied` mapping; factor
  the shared `SCShareableContent` fetch so both files use one error path).
- **Name correlation:** build a `[CGDirectDisplayID: String]` from `NSScreen.screens`
  via `screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]` →
  `NSScreen.localizedName`. Sandbox-safe; no `IODisplayCreateInfoDictionary` (the TODO
  open-question — skip it, the entitlement risk isn't worth it for v1.1).
- Capture path: `SCContentFilter(display:excludingWindows:[])` →
  `SCStreamConfiguration` sized to `display.frame * pointPixelScale` →
  `SCScreenshotManager.captureImage`. Reuse the existing `png(from:)` encoder (promote it
  to a shared helper, or duplicate the 6 lines — duplication is fine here).
- Ambiguous-name resolution throws a distinct `WindowCaptureError` case
  (`ambiguousDisplay([String])`) so the agent can re-ask with an id. Add that case +
  its `description`.

New error cases on `WindowCaptureError`: `displayNotFound(CGDirectDisplayID)`,
`ambiguousDisplay([String])`. (Keep one error enum across both capture files.)

---

## 2. Per-display trust: `peek/DisplayApprovalStore.swift`

Sibling to `AppApprovalStore` — separate store, same shape, low risk (don't generalize
the working app cache).

- Keyed by **display name** (`localizedName`), lowercased — sandbox-safe and stable
  enough across replug; `CGDirectDisplayID` reuse across reboots is unreliable (TODO #11)
  and EDID hashing needs IOKit we're avoiding (§1).
- `trustedDisplaysV1` UserDefaults key, versioned like `trustedAppsV1`.
- `TrustedDisplay { id(=name), displayName, firstApprovedAt }`, `@Published trusted`.
- Methods: `isAlwaysAllowed(name:)`, `allowAlways(name:)`, `revoke(name:)`, `revokeAll()`.
- Audit logging mirrors `AppApprovalStore` (`.private` privacy on the name).

Prompt: generalize `AppApprovalPrompt` into a shared serializer (the queue logic is
identical) OR add a `DisplayApprovalPrompt` reusing the same `serializer` task chain so a
window prompt and a display prompt can't stack. **Recommend** factoring the serializer +
`runModal` shell into a small generic and giving it window/display copy variants — one
NSAlert builder, two message strings. Net: ~30 lines shared, no duplicated race logic.

Display prompt copy: "Allow agent to capture the **<name>** display?" + note that
whole-display capture can include notifications/panels from any app on that screen.

---

## 3. MCP tools — extend `peek/MCPTools.swift`

Add two tool definitions + handlers, mirroring the window ones.

| Tool | Args | Returns |
|---|---|---|
| `list_displays` | `{}` | text summary + `structuredContent.displays[]` (`id`, `name`, `frame{x,y,w,h}`, `is_main`) |
| `capture_display` | `{ id?: integer, name?: string }` | MCP `image` block (base64 PNG) — either-or args |

Handler flow for `capture_display`:
1. Resolve `DisplayInfo` by id or name (name → `resolveDisplay(name:)`, ambiguous →
   `-32602`/`-32603` with the candidate list).
2. `ManagedPreferences.evaluateDisplayCapture()` → `.denied` ⇒ canonical policy message
   (reuse `policyDeniedMessage` style; don't differentiate reasons).
3. `.userControlled`/`.allowed` ⇒ consult `DisplayApprovalStore` + prompt (gate 2),
   same Deny/Once/Always flow as windows.
4. Capture, return image block.

`list_displays` honours nothing to redact today (no title equivalent); it always
enumerates. Note: monitor names can be personal ("Bob's Studio Display") — acceptable,
same disclosure level as `list_windows` app names.

Wire `DisplayApprovalStore` into `PeekMCPDelegate.init` alongside `approvals`.

---

## 4. #7 polish — menu-bar icon states + capture flash

Current UI is SwiftUI `MenuBarExtra` + `MenuBarLabel` (an `Image`). **Keep it** — no
NSStatusItem rewrite (that was a "low priority" note; SwiftUI covers the three states).

- **Icon states** via `MenuBarLabel` reading `AppState`:
  - permission missing → `viewfinder.trianglebadge.exclamationmark` (already done)
  - granted + MCP running → `viewfinder` (optionally `.symbolVariant(.fill)` to read as "active")
  - granted + MCP off → plain `viewfinder`
- **Capture flash:** add `@Published var captureFlash: Bool` to `AppState`; set true for
  ~0.6s at the end of `capture(_:)` (the click-to-clipboard path) and on MCP capture
  completion. `MenuBarLabel` swaps to `checkmark.circle.fill` while flashing. Pure
  SwiftUI, no AppKit. Self-clears via a `Task.sleep`.
- Defer the full NSStatusItem refactor to a later release — log it in TODO as
  explicitly-deferred so it doesn't read as forgotten.

---

## 5. Settings — Trusted Displays

`SettingsView.swift`: the "Trusted Apps" tab becomes **"Trusted"** with two sections
(apps + displays), or add a 4th tab "Trusted Displays". **Recommend** one "Trusted" tab,
two `Section`s, to avoid tab sprawl (already 3 tabs in a 480pt window).

- Inject `DisplayApprovalStore` as a second `@EnvironmentObject` (add to `PeekApp.swift`
  `Settings{}` scene alongside `app.approvals`).
- Mirror the existing `Table` + Revoke / Revoke All for displays.
- Managed-policy section: when `allowScreenCapture` is managed, add a `PolicyRow`
  ("Display capture disabled by policy" / "…managed").

---

## 6. Tests — `peekTests/peekTests.swift`

- `DisplayInfo` value semantics (Hashable/equality) — mirror `WindowInfo` test.
- New `WindowCaptureError` cases → description strings (extend
  `windowCaptureErrorDescriptions`).
- `ManagedPreferences.evaluateDisplayCapture()` tri-state via the `pathsProvider`
  temp-file hook (absent / true / false) — this is the §0 decision, so it gets explicit
  coverage.
- `DisplayApprovalStore` add/revoke/persist round-trip (UserDefaults, suite-isolated).
- Live SCK display capture stays un-unit-tested (needs permission + real displays) —
  covered by §8 manual smoke.

---

## 7. Docs + versioning

- `DESIGN.md`: add `list_displays`/`capture_display` to the MCP surface table; rewrite
  the `allowScreenCapture` row to the tri-state semantics (§0); note per-display trust.
- `TODO.md`: move #11 to ✅ when done; record NSStatusItem refactor as deferred; add the
  §0 decision to the decision log.
- `SETUP.md`: one line on display capture + the per-display prompt.
- `CLAUDE.md`: bump status block to 1.1.
- `PrivacyInfo.xcprivacy`: **no change** (no new data collection).
- Version: `MARKETING_VERSION` 1.0 → **1.1**; `CURRENT_PROJECT_VERSION` 4 → **5**
  (App Store build numbers must stay monotonic across the whole app, not reset per
  marketing version).

---

## 8. #9 live Claude Desktop smoke (manual milestone)

Human-in-the-loop — I can drive the build/launch and prep, but you confirm Desktop:
1. Build + launch 1.1, grant Screen Recording.
2. Verify click-to-clipboard flash + icon states by eye.
3. `Copy Claude Desktop config` → paste into `claude_desktop_config.json` → restart.
4. Confirm `list_windows`, `capture_window`, `capture_app`, **`list_displays`,
   `capture_display`** all appear.
5. "What's on my <monitor name>?" → image returns, per-display prompt fires once,
   Always-Allow persists, Settings shows the trusted display.
6. Curl-verify the two new tools end-to-end (like the 1.0 `capture_app` check) as a
   non-interactive backstop.

---

## Build sequence

```
§0 decision ─→ §1 DisplayCapture ─→ §3 MCP tools ─┐
            └→ §2 DisplayApprovalStore ───────────┤→ §6 tests ─→ build/run
§4 icon polish (independent) ──────────────────────┤
§5 Settings (needs §2) ────────────────────────────┘
§7 docs/version ─→ §8 manual smoke ─→ tag/submit
```

§1+§2 are independent and can land in parallel; §3 needs both; §4 is fully independent.
```
