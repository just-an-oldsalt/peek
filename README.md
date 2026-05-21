# Peek

A macOS menu bar utility that hands captureable app windows to AI agents over a local MCP endpoint. Ask your agent *"what's going on in my Calculator app?"* — it calls `peek.capture_window(...)`, gets a PNG back, answers. No app switching, no manual screenshot-and-paste.

```
You          Agent                   Peek                  ScreenCaptureKit
 │             │                      │                            │
 │  "show me   │                      │                            │
 │  Calculator"│                      │                            │
 │────────────▶│                      │                            │
 │             │  capture_app("Calculator")                        │
 │             │─────────────────────▶│  bearer auth + approval    │
 │             │                      │───────────────────────────▶│
 │             │                      │            PNG             │
 │             │                      │◀───────────────────────────│
 │             │◀── base64 PNG ───────│                            │
 │  "Calc shows 777,777"              │                            │
 │◀────────────│                      │                            │
```

## Highlights

- **Local-only MCP server** bound to `127.0.0.1:11474`. Bearer token in Keychain. Nothing leaves your device.
- **Two-gate trust model**: bearer token (proves the request came from a paired client) + first-time per-app approval (proves *you* consent to capturing that specific app). Manage trusted apps from Settings.
- **No Accessibility entitlement**. ScreenCaptureKit composites occluded window pixels off-screen; Peek never raises, moves, or interacts with another app's windows.
- **App Sandbox on, hardened runtime on.** One non-default entitlement: `com.apple.security.network.server` for the loopback listener.
- **MDM-manageable** via `/Library/Managed Preferences/com.oldsalt.peek.plist` — `enabled`, `mcpServerEnabled`, `allowedApps`, `deniedApps`, `redactWindowTitles`, `disableQuit`.
- **Both human and agent paths.** Click the menu bar icon → pick an app → its frontmost window lands on your clipboard as a PNG. Or wire it up to Claude Code / Claude Desktop / Cursor for the agent flow.

## MCP surface

| Tool | Args | Returns |
|---|---|---|
| `list_windows` | `{ app?: string }` | id, app, title, bounds, pid per captureable window |
| `capture_window` | `{ id: integer }` | PNG of that window's pixels (even if occluded) |
| `capture_app` | `{ name: string }` | PNG of the frontmost window of the named app |

## Install

- **GitHub Releases** (notarized, Developer ID): download the latest `.dmg` or `.pkg` from [releases](https://github.com/just-an-oldsalt/peek/releases).
- **Mac App Store**: coming soon.

Then follow [`SETUP.md`](SETUP.md) for permissions and wiring up your AI client.

## Build from source

```bash
# From the repo root
xcodebuild -project peek.xcodeproj -scheme peek -configuration Debug \
    -destination 'platform=macOS' build

# Run the unit tests
xcodebuild -project peek.xcodeproj -scheme peek \
    -destination 'platform=macOS' test -only-testing:peekTests

# Or open in Xcode
open peek.xcodeproj
```

Requires macOS 14 Sonoma minimum.

## Architectural template

Peek follows the same shape as its sibling [Niacin](https://github.com/just-an-oldsalt/niacin):

- Menu bar agent only (`LSUIElement = YES`, no Dock icon)
- Owns one OS primitive (Peek: ScreenCaptureKit; Niacin: `IOPMAssertion`)
- One binary, two distribution channels (GitHub Releases + Mac App Store)
- Loopback MCP server with bearer-token auth, token in Keychain
- MDM-manageable via the standard managed preferences path

## Project docs

- [`DESIGN.md`](DESIGN.md) — pitch, MCP surface, sandbox story, trust gates, MDM keys, deferred items
- [`SETUP.md`](SETUP.md) — install, permissions, Claude Code + Claude Desktop wiring
- [`RELEASING.md`](RELEASING.md) — Developer ID + App Store release pipeline
- [`TODO.md`](TODO.md) — task status and dependencies
- [`CLAUDE.md`](CLAUDE.md) — onboarding doc for AI agents helping with the codebase

## License

MIT — see [LICENSE](LICENSE).
