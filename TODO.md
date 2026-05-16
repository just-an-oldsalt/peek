# Peek — MVP task list

Status as of 2026-05-15. **MVP shipped** — agent path works end-to-end (verified via `capture_app` round-trip against Calculator). Remaining tasks (#6, #7 polish, #8, #9) are post-MVP hardening.

## Status snapshot

| # | Status | Task |
|---|---|---|
| 1 | ✅ done | Bootstrap Peek Xcode project |
| 2 | ✅ done | Build ScreenCaptureKit harness |
| 3 | ✅ done | Handle Screen Recording permission flow |
| 4 | ✅ done | Port MCP server scaffold from Niacin |
| 5 | ✅ done | Implement MCP tools (`list_windows`, `capture_window`, `capture_app`) |
| 6 | ▢ pending | Per-app approval cache |
| 7 | ◐ partial | Menu bar shell with click-to-clipboard capture (scaffolded — icon state + clipboard work; multi-window submenu, capture-flash, on-demand menuNeedsUpdate parity TBD) |
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

### #2 ✅ Build ScreenCaptureKit harness

Implemented in `peek/WindowCapture.swift` as the `WindowCapture` enum namespace.

Three async entry points, as specified:
- `listWindows(app: String?)` → `[WindowInfo]`
- `captureWindow(id: CGWindowID)` → PNG `Data`
- `captureApp(name: String)` → PNG `Data` (frontmost window of matching app)

Implementation notes for downstream tasks:
- Uses `SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)` so occluded/minimized windows are still enumerable and captureable.
- Captureable-window filter: has owning application, `windowLayer == 0`, non-empty frame. Knocks out Dock / menu-bar / system UI windows; keeps regular app windows whether on-screen or not.
- App match is case-insensitive against both `applicationName` and `bundleIdentifier`. SCK returns windows in z-order, so `windows.first(where:)` is the frontmost match.
- Capture path: `SCContentFilter(desktopIndependentWindow:)` → `SCStreamConfiguration` sized to `contentRect * pointPixelScale` → `SCScreenshotManager.captureImage`. PNG encoding via `NSBitmapImageRep`.
- Errors: `WindowCaptureError` with `permissionDenied` / `windowNotFound(id)` / `appNotRunning(name)` / `captureFailed(Error)` / `encodingFailed`. The `permissionDenied` mapping is a fallback — task #3 owns the real preflight.

Unit tests in `peekTests/peekTests.swift` cover error descriptions and `WindowInfo` value semantics. Live SCK calls aren't unit-tested (they require Screen Recording permission and a real window environment) — task #7 will exercise them end-to-end via the click-to-clipboard menu.

**Blocked by:** #1. ✅ Done.

### #3 ✅ Handle Screen Recording permission flow

Implemented in `peek/ScreenRecordingPermission.swift` and wired through `MenuModel`.

- `CGPreflightScreenCaptureAccess()` is checked on every refresh (non-prompting) and gates `WindowCapture.listWindows`.
- When missing, the menu shows "Screen Recording permission required" + "Grant Screen Recording…" + "After granting, quit and relaunch Peek." Click the grant button → `CGRequestScreenCaptureAccess()` triggers TCC prompt, then deep-links to System Settings → Privacy & Security → Screen Recording.
- Menu bar icon switches between `viewfinder` (granted) and `viewfinder.slash` (missing) via `MenuBarLabel` reading `menu.permissionGranted`.
- Relaunch is required for the TCC grant to apply (macOS quirk — the granted state is fetched at process start). Settings-side helper in #8 can later surface this more clearly.

**Blocked by:** #2. ✅ Done.

### #4 ✅ Port MCP server scaffold from Niacin

`peek/MCPServer.swift` and `peek/MCPTokenStore.swift` ported from Niacin with these deltas:

- Port range `11474...11479` (Niacin reserves `11473...11479`).
- Keychain service `com.oldsalt.peek.mcp` (account `mcp-token`).
- Stripped Niacin's `keep_awake` / `release_awake` / `status` handlers.
- Added a generic `MCPDelegate` protocol in their place: `mcpToolDefinitions() -> [JSONValue]` and `mcpCallTool(name:args:) async throws -> JSONValue`. Tools land in #5 by implementing this protocol.
- New `MCPToolError` enum (`unknownTool` / `invalidArguments` / `internalError`) mapped to JSON-RPC codes -32602 / -32603.
- `serverInfo.name = "peek"`, `protocolVersion = "2024-11-05"` (unchanged from Niacin).
- `dispatch` and `handle` are now `async` so tool calls can await `WindowCapture`.

PeekApp bootstraps the server on launch: generates a Keychain token on first run, starts the listener, surfaces port + Copy MCP token in the menu. Smoke-tested with curl: `initialize` and `tools/list` succeed with bearer; missing bearer → HTTP 401.

**Blocked by:** #1. ✅ Done.

### #5 ✅ Implement MCP tools

`peek/MCPTools.swift` — `PeekMCPDelegate` implements `MCPDelegate` and exposes three tools (unprefixed; Claude Desktop namespaces by server name):

| Tool | Args | Returns |
|---|---|---|
| `list_windows` | `{ app?: string }` | text summary + `structuredContent.windows[]` (`id`, `app`, `bundle_id`, `title`, `bounds{x,y,width,height}`, `pid`) |
| `capture_window` | `{ id: integer }` | MCP `image` content block (base64 PNG, `image/png`) |
| `capture_app` | `{ name: string }` | same — frontmost real window of named app or bundle |

Error mapping: `WindowCaptureError` → `MCPToolError.internalError(...)` → JSON-RPC `-32603`. Missing/invalid args → `-32602`.

**Window filter fix (uncovered by Calculator test):** the system attaches multiple empty-title `1512×33` menu-bar tracking shadows to the active app's pid; they report `windowLayer 0` and z-order ahead of the real window. `WindowCapture.isCaptureableWindow` now drops `title.isEmpty && frame.minY == 0 && frame.height < 50`. Both `list_windows` and the click-to-clipboard menu benefit.

**Smoke-tested via curl:** `tools/list` returns three tools; `capture_app` for Calculator returned a clean 89 KB PNG of the real window. Decoded and verified pixel-perfect (display shows `69,420`).

**Blocked by:** #2, #4. ✅ Done.

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
