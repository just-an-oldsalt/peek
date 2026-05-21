# Peek — App Store submission copy

Everything you need to paste into App Store Connect for the 1.0 submission. Field-by-field. Character counts noted where the limit is tight.

## App information (one-time)

| Field | Value |
|---|---|
| **Bundle ID** | `com.oldsalt.peek` |
| **SKU** | `peek-macos` |
| **Primary Language** | English (U.S.) |
| **Primary Category** | Utilities |
| **Secondary Category** | Developer Tools |
| **Content Rights** | Does not use third-party content |
| **Age Rating** | 4+ (no objectionable content) |

## Version metadata (per submission)

### Name (30 char max)

```
Peek
```

(4 / 30)

### Subtitle (30 char max)

```
Local windows for AI agents.
```

(28 / 30) — trademark-clean; no "Mac", "macOS", or other Apple marks as product modifiers.

### Promotional text (170 char max, editable any time without resubmission)

```
Ask your AI agent what's in any open window — Peek hands it a fresh screenshot over a local-only MCP endpoint. No screenshot-and-paste, no app switching.
```

(157 / 170)

### Description (4000 char max)

```
Peek is a menu bar utility that lets AI agents see your screen on demand. Connect Claude Code, Claude Desktop, Cursor, or any other client that speaks the Model Context Protocol, then ask in natural language — "what's on my Calculator?", "is the build still failing?", "describe the Figma frame I have open" — and the agent gets a fresh PNG of that window without you switching apps or pasting screenshots.

Everything happens on your device. Peek runs a localhost-only MCP listener on 127.0.0.1, authenticated by a bearer token generated on first launch and stored in your Keychain. The first time an agent asks to capture a given app, Peek pops a confirmation prompt — you choose Allow Once, Always Allow, or Deny. Approved apps appear in Settings → Trusted Apps and can be revoked at any time. No data ever leaves your Mac.

KEY FEATURES

• Local MCP server bound to 127.0.0.1 — no outbound network, no telemetry
• Two-gate trust model: bearer token + per-app user approval
• ScreenCaptureKit under the hood — captures occluded and minimized windows without raising them
• No Accessibility entitlement required
• Three MCP tools: list_windows, capture_window, capture_app
• Click-to-clipboard menu for human-initiated captures (no token required — the click is the consent)
• Settings window with MCP / Permissions / Trusted Apps tabs
• Pinned mcp-remote bridge for Claude Desktop compatibility
• App Sandbox on, hardened runtime on, only one non-default entitlement (network.server) for the loopback listener

WORKS WITH

• Claude Code (streamable-HTTP MCP)
• Claude Desktop (via pinned mcp-remote stdio bridge)
• Cursor
• Any MCP client that speaks streamable-HTTP

MANAGED DEPLOYMENT

For organisations, Peek reads MDM-managed preferences from /Library/Managed Preferences/com.oldsalt.peek.plist. IT can lock the MCP server toggle, set bundle-ID allow/deny lists, redact window titles in tool output, and disable Quit. Settings displays every active policy with a lock icon. Deployable through JAMF, Mosyle, Kandji, Intune, or any MDM that pushes preference domains.

PRIVACY

Peek does not collect, transmit, or share any personal data. No analytics, no crash reporting, no advertising identifiers. The full policy lives at https://peek.dort.zone/privacy.

REQUIREMENTS

• macOS 14 Sonoma or later
• Apple Silicon or Intel
• Screen Recording permission (requested on first use)
• An MCP-speaking AI client to connect to it

Peek is open source under the MIT license. Source code, issue tracker, and release archives at https://github.com/just-an-oldsalt/peek.
```

(approx 2,400 / 4,000)

### Keywords (100 char max, comma-separated, no spaces)

```
MCP,AI,agent,Claude,Cursor,screenshot,window,capture,utility,developer,menubar,LLM,context
```

(91 / 100)

### What's New (release notes, 4000 char max)

```
Welcome to Peek 1.0 — the first public release.

• Local-only MCP server with bearer-token authentication and per-app approval prompts.
• Three MCP tools: list_windows, capture_window, capture_app — works with Claude Code, Cursor, and (via the bundled mcp-remote bridge) Claude Desktop.
• Click-to-clipboard menu for human-driven captures.
• Settings window with MCP / Permissions / Trusted Apps tabs.
• Full MDM support via /Library/Managed Preferences/com.oldsalt.peek.plist — allow/deny lists, kill switch, title redaction.
• App Sandbox on, hardened runtime on. ScreenCaptureKit-based — no Accessibility entitlement required.
```

(approx 660 / 4,000)

### Copyright

```
© 2026 Richard Dort
```

## URLs

| Field | Value |
|---|---|
| **Support URL** (required) | `https://github.com/just-an-oldsalt/peek/issues` |
| **Marketing URL** (optional) | `https://peek.dort.zone/` |
| **Privacy Policy URL** (required) | `https://peek.dort.zone/privacy` |

## Pricing & availability

- **Price tier**: Free (USD 0)
- **Availability**: All territories
- **Pre-order**: No

## App privacy nutrition label

Match the `PrivacyInfo.xcprivacy` manifest:

- **Data Used to Track You**: None
- **Data Linked to You**: None
- **Data Not Linked to You**: None

This produces an empty "Privacy" card on the App Store listing, which is correct — Peek collects nothing.

## App Review Information

| Field | Value |
|---|---|
| **First Name** | Richard |
| **Last Name** | Dort |
| **Phone Number** | _(your contact number for reviewer follow-up)_ |
| **Email Address** | _(your reviewer-contact email)_ |
| **Demo Account** | Not required — Peek has no login or backend |

### Notes (paste into the Resolution Center / Review Notes field)

```
Peek is a menu bar utility that exposes a localhost-only MCP (Model Context Protocol) endpoint so AI agents already installed on the user's Mac can request window captures via the standard MCP image content block.

Why network.server entitlement: Peek binds an HTTP listener to 127.0.0.1 (loopback only — acceptLocalOnly = true on NWListener). It has no client networking entitlements and cannot initiate any outbound connections. All requests require a bearer token generated in-app on first launch and stored in the user's Keychain. The first time an agent asks to capture a given app, the user is presented with a confirmation prompt (Allow Once / Always Allow / Deny).

How to test:
1. Launch Peek. A viewfinder icon appears in the menu bar.
2. Grant Screen Recording in System Settings → Privacy & Security → Screen Recording, then relaunch Peek.
3. Click the menu bar icon → "Capture window to clipboard" → pick any app. A PNG of its frontmost window lands on the clipboard. (This path requires no MCP client and demonstrates the core capture functionality.)
4. The MCP path requires an external AI client (Claude Code, Cursor, Claude Desktop). Setup is documented at https://peek.dort.zone/ and in the in-app Settings window. If you cannot configure an external client during review, the click-to-clipboard menu exercises the same ScreenCaptureKit code path.

Privacy: nothing collected, no analytics, no telemetry. PrivacyInfo.xcprivacy ships with empty data-type arrays. UserDefaults is declared with reason CA92.1 (app-internal preferences only — the trusted-apps cache and a single MCP-enabled toggle).

Source code is public at https://github.com/just-an-oldsalt/peek under the MIT license.
```

## Build

- Archive in Xcode (`Product → Archive`, Release config).
- Distribute App → App Store Connect → Upload.
- Wait for processing to finish (typically 15–30 min).
- Return to App Store Connect, select the new build under the version record.

## Screenshots (required — at least one)

Apple now requires Mac App Store screenshots at one of:
- **2880 × 1800** (16:10, default Retina)
- **2560 × 1600**
- **1440 × 900**
- **1280 × 800**

Take at least one, up to ten. Recommended for Peek:

| # | Subject | Caption (optional, max 50 chars) |
|---|---|---|
| 1 | Menu bar dropdown showing "Capture window to clipboard" with apps populated | `Pick any window, get a PNG.` |
| 2 | Settings → MCP tab showing the listener port + Copy Config buttons | `Wire it into any MCP client.` |
| 3 | The NSAlert approval prompt mid-capture | `You approve every new app.` |
| 4 | Settings → Trusted Apps with a few entries | `Revoke trust any time.` |
| 5 | Settings → Managed by Organisation section (if you have a sample plist deployed) | `MDM-deployable, fully manageable.` |

Tip: use `xcrun simctl io` or a real screen recording on a fresh user profile so window contents are clean. Crop the menu bar tightly — the App Store rejects screenshots that look like generic desktop shots.

### Screenshot OS groups (matters since macOS 26)

App Store Connect splits the macOS screenshot section into two groups, gated by what your binary's `MACOSX_DEPLOYMENT_TARGET` supports:

- **Operating Systems Earlier than Version 26** — Sonoma 14, Sequoia 15
- **Operating Systems 26 and Later** — Tahoe 26+

Peek's deployment target is `14.0`, so it qualifies for **both** groups, and App Store Connect requires at least one screenshot in **each** before you can submit. Peek's UI is identical across all three OS major versions, so the simplest move is to **upload the same PNG set to both groups** — drag the same files in twice. Don't take separate "older OS" screenshots unless you actually have a visual difference to show.

If you ever raise the deployment target to 26+, this section collapses to one group automatically.

## Submission checklist

- [ ] Bundle ID matches App Store Connect record
- [ ] `MARKETING_VERSION` = 1.0, `CURRENT_PROJECT_VERSION` ≥ 1, committed
- [ ] `PrivacyInfo.xcprivacy` present in built bundle (verified with `find peek.app -name PrivacyInfo.xcprivacy`)
- [ ] `ITSAppUsesNonExemptEncryption = false` in Info.plist (skips export-compliance prompt)
- [ ] App Sandbox + hardened runtime enabled on Release build
- [ ] All copy above pasted into App Store Connect
- [ ] Privacy policy URL resolves and content matches manifest
- [ ] Build uploaded and finished processing
- [ ] Screenshots uploaded
- [ ] Reviewer note pasted into Review Notes field
- [ ] Submit for review

## Common rejection patterns to avoid

- **5.2.5 Apple Trademarks** — never use "Mac", "macOS", "App Store", "AirDrop", etc. as product modifiers in subtitle, keywords, screenshots, or promotional text. "Local windows for AI agents." is safe; "Local Mac windows for AI agents." is not.
- **2.3.10 Accurate Metadata** — don't promise features you haven't shipped. If something is post-1.0 (e.g. display capture), leave it out of the description.
- **2.1 App Completeness** — the reviewer will try to run it. The click-to-clipboard menu must work without any external client. (It does — that's why it's there.)
- **5.1.1 Data Collection** — the App Privacy section must match `PrivacyInfo.xcprivacy`. Both say nothing.
