# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Peek — agent onboarding

This is the source-of-truth doc for picking up Peek work in any session.

## What this is

**Peek** is a macOS menu bar utility that hands captureable app windows to AI agents over a local MCP endpoint. The wedge: when you ask Claude "what's going on in my Calculator app?", Claude calls `peek.capture_window(...)` over loopback HTTP and gets back a PNG. No app switching, no manual screenshot+paste.

Sibling to **Niacin** (`~/Documents/GIT/niacin`). Same architectural shape, different OS primitive (ScreenCaptureKit instead of `IOPMAssertion`).

## Status — 2026-06-07: 1.1 in development

**1.0 (build 4) shipped — accepted to the App Store.** 1.1 adds multi-display capture
(`list_displays` / `capture_display` with named monitors + a per-display trust gate),
the menu-bar capture-flash + icon states, and the live Claude Desktop smoke. See
`PLAN_1.1.md` for the full plan and `feature/1.1` for the work.

> ⚠️ History note: the accepted build's commit `95c4366` (App Review 5.1.1 neutral-wording
> fix + build→4) was never pushed to origin; PR #3 merged only up to build 2. `feature/1.1`
> carries `95c4366` so it reaches `main` when 1.1 lands. Don't branch 1.x off pre-1.1
> `main` without that commit.

### 1.0 — what landed (2026-05-20)

Agent path + trust gates + Settings + Claude Desktop bridge all landed. App-Store-bound manifests in place.

Done since the 2026-05-15 MVP:
- **#6 Per-app approval cache** — `AppApprovalStore.swift` (UserDefaults), `AppApprovalPrompt.ask` (NSAlert with Deny / Allow Once / Always Allow), revoke UI in Settings → Trusted Apps.
- **#7 ManagedPreferences** — Niacin's MDM resolver ported. Keys: `enabled`, `mcpServerEnabled`, `allowedApps`, `deniedApps`, `allowScreenCapture`, `redactWindowTitles`, `disableQuit`. `evaluate(bundleID:appName:)` is the policy gate consulted before the approval cache.
- **#8 Settings window** — `SettingsView.swift` with three tabs (MCP / Permissions / Trusted Apps) plus a Managed-by-Organisation section that appears when MDM keys are set. SwiftUI `Settings` scene wired in `PeekApp.swift`.
- **#10 Claude Desktop bridge** — pinned `mcp-remote@0.1.38` (`AppState.mcpRemoteVersionPin`). Settings now has separate Copy Claude Code / Copy Claude Desktop buttons.
- **App Store prep** — `PrivacyInfo.xcprivacy` (no data collection, UserDefaults declared with reason `CA92.1`), `Info.plist` (`ITSAppUsesNonExemptEncryption=false`, copyright filled), `scripts/release.sh` + `RELEASING.md`, `SETUP.md`.
- Refactor: old `MenuModel` → `AppState.shared` so the menu bar and Settings window share state. `PeekMCPDelegate` now takes the approval store via init.

Still open:
- **#9 Live Claude Desktop smoke** — Claude Code path is curl-verified end-to-end; the Desktop path needs a human-driven run-through of `SETUP.md` once a real install happens.
- **#7 polish** — capture-flash on click-to-clipboard, NSStatusItem refactor for richer icon states (low priority).
- **#11 Multi-display** — deferred to 1.1.
- See `TODO.md` for the full task list and dependencies.
- See `DESIGN.md` for the full design rationale.

## Build, run, test

```bash
# Build from CLI
xcodebuild -project peek.xcodeproj -scheme peek -configuration Debug -destination 'platform=macOS' build

# Run the unit test target (peekTests). peekUITests is a template stub and
# is skipped by default — its runner needs Accessibility and the app has no
# foreground UI for XCUIApplication() to attach to.
xcodebuild -project peek.xcodeproj -scheme peek -destination 'platform=macOS' \
  test -only-testing:peekTests

# Run a single Swift Testing test by function name
xcodebuild -project peek.xcodeproj -scheme peek -destination 'platform=macOS' \
  test -only-testing:peekTests/windowCaptureErrorDescriptions

# Or just open in Xcode (⌘R to run, ⌘U for tests)
open peek.xcodeproj
```

Built binary lives under `~/Library/Developer/Xcode/DerivedData/peek-*/Build/Products/Debug/peek.app`. Launch it and look for the viewfinder icon in the menu bar (right side).

## Architectural conventions — do not drift

This codebase is a deliberate clone of Niacin's shape. Keep these locked unless explicitly redesigning:

- **Menu bar agent only** — `LSUIElement = YES` in Info.plist, no Dock icon
- **macOS 14 Sonoma** minimum
- **App Sandbox on**, hardened runtime on
- **Only one non-default entitlement:** `com.apple.security.network.server` (for the loopback MCP listener)
- **Bundle ID:** `com.oldsalt.peek`
- **MCP port:** `11474` (Niacin owns `11473`)
- **MCP token:** generated on first run, stored in Keychain, surfaced in Settings for the user to copy into Claude Desktop config
- **No Accessibility entitlement** — we never raise/move/manipulate windows. ScreenCaptureKit composites occluded pixels for us. (Don't reintroduce AX out of habit; see DESIGN.md "Sandbox & permissions".)

## MVP scope — do not drift

The MVP is **agent-initiated only**. The user asked for this explicitly. There is a deliberate v2 deferral on:

- Global hotkey + region selector
- Floating prompt window for typing a question at capture time
- `peek.latest()` staging buffer for human-staged captures
- OCR endpoint (return pixels; let the LLM read)
- Annotation tools
- Disk persistence of captures

Plus one **fun feature that IS in MVP** — a click-to-clipboard menu (task #7):
> Clicking the menu bar icon shows a dynamic list of running apps with captureable windows. Click an app → frontmost window of that app is captured and dropped into the clipboard as a PNG. Human-initiated, so the click is the consent — no token, no per-app prompt.

This gives Peek a useful "demo mode" before MCP is wired up, and gives users a confidence check without configuring Claude Desktop.

## How work happens here

- **Source layout:** synchronized folder groups in the pbxproj — any `.swift` file dropped into `peek/` is automatically picked up. No pbxproj edits needed to add source.
- **Tests:** Swift Testing framework (`import Testing` + `@Test`), same as Niacin. Run via `Cmd-U` in Xcode or `xcodebuild test`.
- **Niacin patterns worth porting verbatim:**
  - `MCPServer.swift` + `MCPTokenStore.swift` for the loopback HTTP/JSON-RPC scaffold and Keychain token management
  - `ManagedPreferences.swift` for the MDM plist resolver
  - `SettingsView.swift` for the settings shell layout
  - `AboutView.swift` for the about window
- **Commit style:** see `git log --oneline` in `../niacin`. Short imperative subject, body explains the why.

## Pointers

- `DESIGN.md` — the spec: pitch, MCP surface, sandbox story, trust gates, MDM keys, deferred items.
- `TODO.md` — the 9-task MVP plan with dependencies and status.
- `../niacin/` — the sibling app. Reference implementation for everything from MCP server to release pipeline.

## Memory note

If this is a fresh Claude session, project memory may be empty. The two memory files worth knowing existed in the parent session (`/Users/richarddort/.claude/projects/-Users-richarddort-Documents-GIT-niacin/memory/`):

- `project_niacin_shape.md` — the architectural template described above.
- `project_peek.md` — the Peek-specific scope locks (MVP framing, agent-first, deferred items).

Their content is reproduced in this file and in `DESIGN.md`. If you need them in the new project's memory directory, write equivalent entries from this file.
