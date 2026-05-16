# Peek — design

## The pitch

A macOS menu bar utility that hands captureable app windows to AI agents over a local MCP endpoint. Agent says *"what's going on in my Calculator app?"*, calls `peek.capture_window(id)` over loopback HTTP, gets a PNG back, answers.

## Why this is interesting

The everyday user workflow Peek replaces:
1. Take a screenshot (`⌘⇧4`)
2. Switch to Claude
3. Paste the image
4. Type the question
5. Wait

The Peek workflow:
1. Ask Claude in natural language about a specific app

The agent does the rest. The friction reduction is real for users who already screenshot-and-ask multiple times a day.

## Architectural template — the "Niacin shape"

Peek follows the same pattern as [Niacin](../niacin/README.md):

- Menu bar agent (`LSUIElement = YES`, no Dock icon)
- Owns one OS primitive (Peek: ScreenCaptureKit; Niacin: `IOPMAssertion`)
- App Sandbox on, hardened runtime on, minimum entitlements
- Loopback MCP server with bearer-token auth, token in Keychain
- One binary, two distribution channels (GitHub Releases + Mac App Store)
- MDM-manageable via `/Library/Managed Preferences/com.oldsalt.peek.plist`

## MCP surface (loopback only)

Listener bound to `127.0.0.1:11474`, JSON-RPC, bearer token required on every request.

| Tool | Args | Returns |
|---|---|---|
| `peek.list_windows` | `{ app?: string }` | `[{ id, app, title, bounds }, …]` |
| `peek.capture_window` | `{ id: number }` | MCP `image` content block (base64 PNG) |
| `peek.capture_app` | `{ name: string }` | Same — convenience: frontmost window of named app |

`peek.capture_screen` (whole display) is on the wall but **not in MVP** — different privacy surface, can be added once the per-app trust UX is solid.

### What we deliberately don't expose

- **No raw clipboard write from MCP.** The click-to-clipboard menu is human-initiated only; an agent can't dump arbitrary data into your pasteboard.
- **No window manipulation.** No raise, no move, no resize. Peek reads pixels; that's it.
- **No keystroke/click synthesis.** Not in scope.

## Sandbox & permissions — the SCK insight

The naive mental model: "for an agent to see Calculator, Peek has to bring Calculator to the front, get its bounds, screenshot it." That path requires Accessibility, which is a sandbox quagmire.

**What ScreenCaptureKit actually does:** you ask `SCShareableContent` for the list of windows; you get IDs. You call `SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w))` and get the pixels of *that* window, composited off-screen. Occluded windows, background Spaces, even minimized windows in many cases — all captured without disturbing what the user sees.

| Capability | Sandbox status | Need it? |
|---|---|---|
| Capture a specific window's pixels (even occluded) | ✅ ScreenCaptureKit, public API | **yes** |
| Enumerate windows + apps | ✅ `SCShareableContent` | yes |
| Raise / move / resize another app's window | ⚠️ Accessibility | **no** |
| Read another app's UI text/labels | ⚠️ Accessibility | no — we send pixels to the LLM |
| Synthesize clicks/keys in another app | ⚠️ Accessibility | no |
| Launch a not-yet-running app | ✅ `NSWorkspace.openApplication` | only if we add "auto-launch closed app" later |

**Permission cost:** one Screen Recording grant, prompted on first capture. Window *titles* require this permission too (since macOS 14.4-ish), so we'd pay it either way.

**Proof points** (all sandboxed App Store apps doing this today): Shottr, CleanShot X, Rectangle Pro.

## Trust gates

Two gates, both light-touch:

1. **MCP bearer token** — every JSON-RPC request must present `Authorization: Bearer <token>`. Token is generated on first launch, stored in Keychain, surfaced in Settings for the user to copy into Claude Desktop config. Regenerable.
2. **Per-app first-capture approval** — first time an MCP-driven capture targets a given app bundle ID, surface an approval prompt (NSAlert or floating panel): *"Peek wants to capture <App> for an agent request — Allow / Deny / Always Allow"*. Remember the decision in UserDefaults. Settings UI to view/revoke.

**Deliberately not in v0:**
- Per-call approval toasts (gets noisy fast)
- Time-bounded approvals ("allow for the next 10 minutes")

**The human path bypasses both gates** because the click *is* the consent:
> Click the menu bar icon → list of running apps → click one → PNG dropped on the clipboard. No token check, no app approval.

## MDM keys (port from Niacin)

Standard location: `/Library/Managed Preferences/com.oldsalt.peek.plist`. Keys present in the managed domain override the user preference and lock the corresponding UI control with a 🔒.

| Key | Type | Default | Effect |
|---|---|---|---|
| `enabled` | Bool | `true` | Master kill switch |
| `mcpServerEnabled` | Bool | `false` | Whether the loopback MCP listener starts |
| `allowedApps` | Array of String | *(none)* | Restrict captureable apps to this bundle-ID allowlist |
| `deniedApps` | Array of String | *(none)* | Always-denied bundle IDs (overrides user approval) |
| `allowScreenCapture` | Bool | `false` | Whether `peek.capture_screen` (whole display) is permitted at all |
| `redactWindowTitles` | Bool | `false` | Strip window titles from `list_windows` output (some titles leak document names) |
| `disableQuit` | Bool | `false` | Remove Quit from the menu bar menu |

Niacin's `ManagedPreferences.swift` resolver is portable as-is; just swap the bundle ID and the key list.

## Two user-facing paths

Peek has two paths the user can take, with deliberately different trust shapes:

| Path | Trigger | Gate | Output |
|---|---|---|---|
| **Human** | Click menu bar icon → app name | The click | PNG on clipboard |
| **Agent** | MCP `peek.capture_*` call | Token + per-app trust | PNG in MCP response |

The human path is built in **task #7**. The agent path is built in tasks **#4–#6**.

## Deliberate v2 cuts

These came up during scoping and are explicitly deferred — do not re-introduce without a conversation:

- **Global hotkey + region selector.** Human-initiated region capture with a floating "ask a question" prompt. Real product work; not in MVP.
- **`peek.latest()` staging buffer.** Holds the most recent human-staged capture+question for an agent to pull.
- **OCR endpoint.** Return pixels; let the LLM read. On-device Vision OCR is a perf optimization, not a feature.
- **Annotation.** CleanShot owns that space.
- **Disk persistence.** Default off. May add as opt-in for "audit my agent's captures" workflows.
- **`peek.capture()` agent-initiated full screen.** Adds different privacy weight than per-window capture; ship per-window first.
- **Multi-window submenu.** Apps with multiple windows: MVP grabs frontmost. A submenu listing each window is a v2 cut.
- **Auto-launch closed apps.** "What's in Calculator" when Calculator is closed → MVP returns "not running" rather than starting it.

## Open design forks (worth thinking about before they ship)

- **Frontmost-of-app vs all-windows on `peek.capture_app`.** Right now spec says frontmost. Agent could also be returned the list and asked to pick. Frontmost is simpler and matches user intent in the common case.
- **What does the per-app approval prompt look like?** NSAlert is reliable but interruptive. A floating panel near the menu bar is friendlier but more code. Start with NSAlert, upgrade later.
- **Token rotation policy.** Niacin lets users regenerate manually. Should Peek auto-rotate on a schedule? Probably not for v0 — the token never leaves the loopback. But worth revisiting if the agent ecosystem starts caching tokens.
- **App Store reviewability.** ScreenCaptureKit + sandbox is fine, but the per-app trust UX needs to be reviewer-legible. Niacin's MDM transparency story sells well; Peek's trust gates should be just as clearly documented in the review notes.
