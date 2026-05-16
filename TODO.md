# Peek — MVP task list

Status as of 2026-05-15. Mirrors the harness task tool but is the durable copy.

## Status snapshot

| # | Status | Task |
|---|---|---|
| 1 | ✅ done | Bootstrap Peek Xcode project |
| 2 | ▢ pending | Build ScreenCaptureKit harness |
| 3 | ▢ pending | Handle Screen Recording permission flow |
| 4 | ▢ pending | Port MCP server scaffold from Niacin |
| 5 | ▢ pending | Implement MCP tools (`list_windows`, `capture_window`, `capture_app`) |
| 6 | ▢ pending | Per-app approval cache |
| 7 | ▢ pending | Menu bar shell with click-to-clipboard capture |
| 8 | ▢ pending | Settings window |
| 9 | ▢ pending | End-to-end smoke test with Claude Desktop |

## Build order

```
1. Bootstrap Xcode project   ✅
   ├→ 2. SCK harness  ─→ 3. Permission flow ─→ 7. Menu bar + clipboard  ← useful app
   │                  ↘                                                  │
   │                    5. MCP tools ──────────→ 6. Per-app approval ────┤
   └→ 4. MCP scaffold ↗                                                  │
                                                          8. Settings ───┤
                                                                          ↓
                                                          9. Smoke test
```

After **1 → 2 → 3 → 7** the menu bar app is dogfood-able with no MCP code. The agent path lights up at task **#5**.

## Task details

### #1 ✅ Bootstrap Peek Xcode project

**Status:** completed in commit `43826fd`. Xcode project bootstrapped with bundle id `com.oldsalt.peek`, App Sandbox + hardened runtime + `com.apple.security.network.server` entitlement, `LSUIElement = YES`, macOS 14 target, same signing/team config as Niacin (`DEVELOPMENT_TEAM = 346JJCHZP7`). Synchronized folder groups, so dropping `.swift` files into `peek/` auto-adds them to the target.

### #2 Build ScreenCaptureKit harness

Wrap `SCShareableContent.current` for window enumeration (filter by app name, return `id`/`title`/`bounds`/`pid`) and `SCScreenshotManager.captureImage(contentFilter:configuration:)` for single-window capture. Captures occluded windows without raising them.

Three entry points:
- `listWindows(app: String?)` → `[WindowInfo]`
- `captureWindow(id: CGWindowID)` → PNG `Data`
- `captureApp(name: String)` → PNG `Data` (frontmost window of named app)

File: `peek/WindowCapture.swift`. **Blocked by:** #1.

### #3 Handle Screen Recording permission flow

Detect permission state at launch and on first capture. `CGPreflightScreenCaptureAccess()` for status, `CGRequestScreenCaptureAccess()` to trigger system prompt.

On denied: surface in-app helper with deep link to `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`. Menu bar icon reflects status (red dot if missing).

**Blocked by:** #2.

### #4 Port MCP server scaffold from Niacin

Loopback HTTP listener on `127.0.0.1:11474`, JSON-RPC, bearer-token auth, token stored in Keychain (generated on first run, regenerable from Settings).

Direct ports from Niacin:
- `peek/MCPServer.swift` ← `niacin/MCPServer.swift`
- `peek/MCPTokenStore.swift` ← `niacin/MCPTokenStore.swift`

Update: new endpoint, new port (`11474`), tool registry empty for now (tasks #5 wires it up).

**Blocked by:** #1.

### #5 Implement MCP tools

Wire the ScreenCaptureKit harness into MCP tool handlers.

| Tool | Args | Returns |
|---|---|---|
| `peek.list_windows` | `{ app?: string }` | array of `{id, app, title, bounds}` |
| `peek.capture_window` | `{ id: number }` | MCP image content (base64 PNG) |
| `peek.capture_app` | `{ name: string }` | same, frontmost of named app |

Error cases: window-not-found, permission-denied, app-not-running. Return MCP-standard image content blocks, not raw base64 strings.

**Blocked by:** #2, #4.

### #6 Per-app approval cache

On first capture targeting a given app bundle ID, show approval prompt (`NSAlert` for v0): *"Peek wants to capture &lt;App&gt; for an agent request — Allow / Deny / Always Allow"*. Remember decision in UserDefaults.

Settings UI to view/revoke trusted apps. MCP token is gate 1; this is gate 2.

The human-initiated clipboard menu (task #7) does **not** trigger this gate — the click is consent.

**Blocked by:** #5.

### #7 Menu bar shell with click-to-clipboard capture

`NSStatusItem` with a Peek icon. Three visual states:
- idle (gray)
- MCP active (filled)
- permission missing (red dot overlay)

Static menu items: Enable/Disable MCP, Settings…, About, Quit.

**Plus the fun feature** — a dynamic "Capture window" section populated on `menuNeedsUpdate:`. One entry per running app that has captureable windows (filter via `SCShareableContent`). Click → `SCScreenshotManager` captures frontmost window of that app → PNG written to `NSPasteboard` (both `.png` and `.tiff` for max compat). Brief icon flash to confirm.

Multi-window apps just grab frontmost in MVP. Submenu listing each window is a v2 cut.

**Blocked by:** #3 (needs working capture + permission flow).

### #8 Settings window

SwiftUI settings scene mirroring Niacin's structure (`niacin/SettingsView.swift` is the template). Sections:

- **MCP** — enable toggle, port display, token regenerate button, "Copy Claude Desktop config snippet" helper
- **Permissions** — Screen Recording status + fix link
- **Trusted Apps** — list of approved bundle IDs from the per-app cache, with revoke buttons

No standalone "test capture" button — the menu bar's click-to-clipboard feature *is* the user's confidence check.

**Blocked by:** #4, #6.

### #9 End-to-end smoke test with Claude Desktop

Generate Claude Desktop MCP config snippet from Settings → paste into `~/Library/Application Support/Claude/claude_desktop_config.json` → restart Claude → confirm `peek.list_windows` and `peek.capture_window` tools appear → run "what's in my Calculator app?" → verify image returns and Claude reads it correctly.

Document the setup in a `SETUP.md`.

**Blocked by:** #5, #8.

## Decision log

Calls already made during scoping. Do not re-litigate without a conversation:

- **Repo:** standalone at `~/Documents/GIT/peek`, not a sibling target in Niacin.
- **Bundle ID:** `com.oldsalt.peek`.
- **MCP port:** `11474` (Niacin uses `11473`).
- **Approval model:** MCP bearer token (gate 1) + per-app first-capture trust cache (gate 2). No per-call toasts.
- **Image return format:** base64 PNG inside MCP-standard `image` content blocks, not raw base64 strings.
- **MVP framing:** agent-initiated only. Human-initiated hotkey+region+question flow is deferred to v2.
- **Click-to-clipboard menu** is in MVP (task #7) — it's the demoable "useful app even without MCP" hook.
- **No Accessibility entitlement.** Ever. SCK composites occluded pixels for us.
- **No agent-initiated full-screen capture** (`peek.capture_screen`) in v0 — per-window only.
- **No OCR endpoint.** Return pixels; let the LLM read.
