# Peek — Privacy Policy

_Last updated: 2026-05-20_

Peek is a macOS menu bar utility that lets you, the user, hand captureable window pixels to AI agents you have already configured on your own machine. Peek runs entirely on your device. This page describes — exhaustively — what data it touches and what it never does.

## What Peek collects

**Nothing.** Peek does not collect, transmit, log to a remote server, or share any personal data, usage data, diagnostic data, or telemetry. There is no analytics SDK, no crash reporter that leaves the device, and no identifier-for-advertisers usage.

This is enforced at the OS level by the App Sandbox: Peek ships with a single non-default entitlement — `com.apple.security.network.server` — which permits it to bind a listener on `127.0.0.1` (loopback) so AI clients running on the *same* Mac can talk to it. Peek has no client networking entitlements and cannot initiate outbound connections to the public internet.

The shipping `PrivacyInfo.xcprivacy` manifest declares:

- `NSPrivacyCollectedDataTypes` — empty array (no data collected)
- `NSPrivacyTracking` — `false`
- `NSPrivacyTrackingDomains` — empty array

The only required-reason API declared is `UserDefaults` (reason `CA92.1`), used to store app-internal preferences — see below.

## What Peek stores locally

Peek keeps a small amount of state inside its own sandboxed container on your Mac. It never leaves your device.

| What | Where | Why |
|---|---|---|
| Bearer token for the local MCP server | macOS Keychain (`com.oldsalt.peek.mcp` service) | Authenticates AI clients you have configured. You can rotate or revoke from Settings → MCP. |
| List of bundle IDs you have tapped **Always Allow** for | App's `UserDefaults` (`trustedApps` key) | So Peek can skip the approval prompt for apps you have already trusted. View and revoke from Settings → Trusted Apps. |
| `mcpServerEnabled` toggle state | App's `UserDefaults` | Remembers whether you want the local MCP server running. |

That's the complete list. There is no on-disk persistence of captured screenshots, no audit database, no log of which apps an agent has captured.

## What Peek reads when capturing

When an AI agent calls `capture_window` or `capture_app` (and you grant the per-app approval), Peek asks ScreenCaptureKit to composite that window's pixels into a PNG. The PNG is returned to the requesting AI client over the loopback HTTP listener and is not retained by Peek.

Peek does **not**:

- Raise, move, resize, focus, or otherwise interact with any window. It only reads pixels.
- Use Accessibility (`AXIsProcessTrusted`) — that entitlement is not declared and not requested.
- Synthesize clicks, key presses, or any other user input.
- Read text out of windows via OCR. Pixels go to the AI client; what the AI client does with them is between you and that client.
- Capture audio, the camera, or the microphone.

Screen Recording (TCC) consent is requested once on first use, per macOS rules. Without it, Peek cannot enumerate or capture any windows at all.

## What your AI client may do with the pixels

Once Peek hands a PNG to your local AI client (Claude Desktop, Claude Code, Cursor, etc.), that client's own privacy policy applies. Many of these clients send the image to a hosted model for inference, so a screenshot of e.g. Calculator may be transmitted to your AI provider. **This is the data flow you opt into when you install an AI agent and connect Peek to it — it is not something Peek does on its own.** Peek's per-app approval prompt is your opportunity to control which apps that flow is allowed for.

## MDM-managed deployments

If Peek is installed under management (`/Library/Managed Preferences/com.oldsalt.peek.plist`), an IT administrator may restrict which bundle IDs can be captured (`allowedApps` / `deniedApps`), redact window titles in tool output (`redactWindowTitles`), or disable the MCP server entirely (`mcpServerEnabled = false`). The Settings window surfaces a "Managed by Organisation" section so you can see which keys are in force. The managed plist is read directly from disk and never transmitted off device.

## Children

Peek is a developer utility. It is not directed at children and does not knowingly collect data from anyone, of any age, by design.

## Changes to this policy

If this policy materially changes, the updated version will be published at the same URL with a new "Last updated" date and called out in the release notes for the version that contains the change.

## Contact

Questions, concerns, or responsible-disclosure reports: [open an issue](https://github.com/just-an-oldsalt/peek/issues) on the GitHub repository, or email the address listed in the App Store record once Peek is published.
