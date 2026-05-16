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
| 10 | ▢ pending | Claude Desktop support via stdio bridge |
| 11 | ▢ pending | Display enumeration + per-monitor capture |

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

Generate Claude Desktop MCP config snippet from Settings → paste into `~/Library/Application Support/Claude/claude_desktop_config.json` → restart Claude → confirm `list_windows` and `capture_window` tools appear → run "what's in my Calculator app?" → verify image returns and Claude reads it correctly.

Document the setup in a `SETUP.md`.

**Blocked by:** #5, #8, #10.

### #10 Claude Desktop support via stdio bridge

**Why:** Discovered during the MVP smoke that Claude Desktop's `claude_desktop_config.json` rejects the streamable-HTTP `url` shape Niacin and Peek's `Copy Config` emit — popups *"Some MCP servers could not be loaded… entries are not valid MCP server configurations and were skipped: peek"*. Claude Desktop currently only honours the stdio transport (`command` + `args`).

The agent path otherwise works end-to-end (verified via curl from Claude Code), so this is purely a transport-bridging problem.

**Approach options:**
1. **`mcp-remote` proxy.** The well-trodden Anthropic-ecosystem npm package. Config becomes:
   ```json
   { "mcpServers": { "peek": { "command": "npx",
     "args": ["-y", "mcp-remote@<pin>", "http://127.0.0.1:11474/",
              "--allow-http", "--transport", "http-only",
              "--header", "Authorization: Bearer <token>"] } } }
   ```
   - Pin a version (`mcp-remote@x.y.z`) to avoid drift.
   - Document the third-party-exec trust trade-off in `SETUP.md` and Settings UI — Claude Desktop will fetch and run this on every launch.
   - Update `MenuModel.copyMCPConfig()` to emit a Claude-Desktop-flavoured snippet (or have two buttons: *Copy Claude Code config* / *Copy Claude Desktop config*).

2. **Ship a Peek-native stdio shim.** A tiny CLI binary (or Swift script) inside the bundle that speaks stdio MCP to Claude Desktop and proxies to the in-process HTTP server. Avoids the npm dependency but is more code to maintain. Most apps in this space go option 1.

3. **Wait for native HTTP MCP in Claude Desktop.** Anthropic is moving in that direction across clients. When it lands, just point users at the existing `Copy Config` snippet. Track the rollout — if it's near, the bridge work may not be worth shipping.

**Trust-gate prereq:** #6 (per-app approval cache) must land before this is dogfooded, especially via the remote-tools path. Once Claude Desktop is a bridge for off-device requests, the per-app NSAlert is the only meaningful safeguard between an agent and Slack/1Password/whatever else is captureable.

**Current state:** the bare-URL snippet from `Copy Claude Desktop config` works with Claude Code and is what Peek ships in v0. Claude Desktop users can paste it but will see the warning popup until #10 lands.

**Blocked by:** #5 (done). **Should sequence after:** #6.

### #11 Display enumeration + per-monitor capture

**Why:** Today peek's surface is window-only. Users with multi-monitor setups want to say "what's on my Dell display" or "have a look at my laptop screen" — the agent should be able to address displays by their human-recognizable names, not just window IDs. Also unlocks "what's on my other screen right now?" check-in flows for the remote-tools-while-away scenario.

**Approach:**

- Extend `WindowCapture` (rename to `Capture`?) with display-side equivalents:
  - `listDisplays()` → `[DisplayInfo]` from `SCShareableContent.current.displays`.
  - `captureDisplay(id: CGDirectDisplayID)` → PNG via `SCContentFilter(display:excludingWindows:)`.
- `DisplayInfo` should carry `id`, `frame`, `width`, `height`, `isMain`, and crucially `name` — pull from `NSScreen.localizedName` after correlating by `CGDirectDisplayID` (`NSScreen.deviceDescription[NSScreenNumber]`). That gives the LLM strings like "Built-in Retina Display", "DELL U2720Q", "LG UltraFine 27" — names users actually recognize.
- New MCP tools, mirroring the window ones:
  - `list_displays` → `[{id, name, frame, is_main}, …]`.
  - `capture_display` → `{ id?: number, name?: string }`. Either-or args; `name` does a case-insensitive substring match against `localizedName`. Reject ambiguous matches with a clear error so the agent can re-ask or fall back to `id`.

**Trust gates:**
- Whole-display capture has a wider privacy surface than per-window — a Slack notification, a 1Password panel, an email preview can sit on any display. The MDM key `allowScreenCapture` (already in DESIGN.md) defaults to **false** for exactly this reason. `list_displays` should still work when `allowScreenCapture` is false (it leaks display geometry, not pixels); `capture_display` must return a policy-denied error.
- Per-display approval cache (sibling to #6's per-app one). First `capture_display` of a given display id pops Allow / Deny / Always-Allow. Trust decisions live in user defaults keyed by display vendor+model (so an external monitor unplugged and replugged isn't re-prompted) — though `CGDirectDisplayID` reuse across reboots is unreliable, so key by name+EDID hash if `IODisplayCreateInfoDictionary` cooperates within the sandbox; fall back to display name otherwise.

**Open questions:**
- Does `IODisplayCreateInfoDictionary` work under App Sandbox without an extra entitlement? Need to verify — if not, we lean entirely on `NSScreen.localizedName` (which is sandbox-safe). For MVP that's probably fine.
- Should `capture_window` opportunistically capture the display when the requested window ID is ambiguous (e.g. multiple Calculator windows on different monitors)? Probably not — explicit per-tool, explicit args.
- Headless / closed-lid behaviour: the built-in display may be present in `SCShareableContent.displays` but invisible. Surface `isActive` if SCK provides it (it does, via `SCDisplay.frame.size`-vs-`mainDisplayID` heuristics).

**Blocked by:** #6 (per-app approval cache informs the per-display variant). Could land independently if the MVP gate is "respect `allowScreenCapture` MDM key + on-by-default approval prompt for any display capture" without the broader per-display memory.

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
