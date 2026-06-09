# Setting up Peek

Peek hands your AI agent the contents of any captureable Mac window over a local-only MCP endpoint. This guide walks through first launch, granting permissions, and wiring up Claude Code or Claude Desktop.

## 1. Install

Download the latest `peek-X.Y.dmg` from [GitHub Releases](https://github.com/just-an-oldsalt/peek/releases), drag **Peek** into Applications, and launch it. Or install via the Mac App Store once published.

You'll see a viewfinder icon (⌖) appear in the menu bar. If the icon has a slash through it, Peek is waiting on Screen Recording permission — see step 2.

## 2. Grant Screen Recording

Peek uses ScreenCaptureKit to read window pixels. macOS requires Screen Recording consent for that, even though Peek never raises or moves the windows it reads.

1. Click the menu bar icon → **Settings…** → **Permissions** tab.
2. Click **Open System Settings…** → enable **Peek** in *Screen & System Audio Recording*.
3. **Quit and relaunch Peek** so the new grant takes effect. (macOS captures the TCC state at process start; without a relaunch the listener still thinks it's denied.)

After relaunch the icon should be solid. As a sanity check, click the icon → **Capture window to clipboard** → pick any running app — the frontmost window's PNG lands on your clipboard.

## 3. Connect your AI client

Peek's MCP server starts on `127.0.0.1:11474` (or the next free port in `11474–11479`) the first time you launch. Open **Settings → MCP** to see the chosen port and your bearer token.

### Claude Code

1. **Settings → MCP → Copy Claude Code config**.
2. Paste into your Claude Code MCP config — usually `~/.claude.json` or similar. The snippet looks like:
   ```json
   {
     "mcpServers": {
       "peek": {
         "url": "http://127.0.0.1:11474",
         "headers": {
           "Authorization": "Bearer <your-token>"
         }
       }
     }
   }
   ```
3. Restart Claude Code. In a new conversation, ask: *"List the windows Peek can capture."* You should see `mcp__peek__list_windows` invoked and the result returned.

**Per-project shortcut:** instead of editing your global config, use **Settings → MCP → Save .mcp.json to a project…** to drop a ready-to-use `.mcp.json` (with your token) into a project folder. Claude Code reads it automatically when launched there. ⚠️ That file contains your bearer token — add `.mcp.json` to the project's `.gitignore`; never commit it. Rotate the token from **Settings → MCP** if it ever leaks.

### Claude Desktop

Claude Desktop doesn't accept the streamable-HTTP `url` shape yet, so Peek ships a stdio bridge via the pinned `mcp-remote` package (fetched on launch by `npx`).

1. Make sure you have Node.js installed (`node --version`). Claude Desktop will spawn `npx -y mcp-remote@…` on every launch.
2. **Settings → MCP → Copy Claude Desktop config**.
3. Open `~/Library/Application Support/Claude/claude_desktop_config.json` and merge the snippet:
   ```json
   {
     "mcpServers": {
       "peek": {
         "command": "npx",
         "args": [
           "-y",
           "mcp-remote@0.1.38",
           "http://127.0.0.1:11474/",
           "--allow-http",
           "--transport",
           "http-only",
           "--header",
           "Authorization: Bearer <your-token>"
         ]
       }
     }
   }
   ```
4. **Quit and relaunch Claude Desktop**. Look for the 🔧 icon in the chat input — Peek's five tools (`list_windows`, `capture_window`, `capture_app`, `list_displays`, `capture_display`) should appear.
5. Try: *"What's currently displayed in my Calculator app?"* Claude will call `capture_app`, Peek will surface an **Allow** prompt the first time, and the screenshot will be passed back to Claude.
6. For whole-monitor capture (1.1), try: *"What's on my Built-in Retina Display?"* Claude calls `list_displays` to find it by name, then `capture_display`. Peek pops a separate per-display approval prompt the first time.

## 4. Per-app approval prompts

The first time an agent asks to capture a given app, Peek pops a system alert:

> *Allow agent to capture Calculator?*
> [Deny] [Allow Once] [Always Allow]

- **Allow Once** — proceed but re-prompt next time.
- **Always Allow** — proceed and add the app to your trusted list. Manage / revoke from **Settings → Trusted → Apps**.
- **Deny** — return a policy error to the agent for this call.

The bearer token (gate 1) proves the request came from a paired client. The approval prompt (gate 2) proves *you* consent to that client capturing this specific app.

**Whole-display capture (1.1)** uses the same two gates with a separate per-display prompt
(*"Allow agent to capture the … display?"*), since a full screen can expose notifications
and panels from any app. Trusted displays are managed under **Settings → Trusted →
Displays**. Organisations can disable display capture entirely with the `allowScreenCapture`
managed preference set to `false`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Icon stays slashed after granting permission | Quit and relaunch Peek — TCC state is captured at process start. |
| Claude Desktop shows a popup *"could not be loaded… peek"* | You pasted the Claude Code URL snippet by mistake. Use **Copy Claude Desktop config**, which wraps the bearer auth in `mcp-remote`. |
| `npx mcp-remote@… not found` in Claude Desktop logs | Node.js isn't installed or `npx` isn't on the path Claude Desktop sees. Install Node from nodejs.org and relaunch Claude Desktop. |
| Agent gets "unauthorized" 401 from `list_windows` | The token in the agent config doesn't match the current one. Re-copy from **Settings → MCP** (you may have rotated, or this is a fresh install). |
| Agent gets "blocked by your organisation's policy" | An MDM `deniedApps` or `allowedApps` rule excludes this app — check **Settings → MCP → Managed by Organisation**. |
| Want to see what Peek is doing | `log show --predicate 'subsystem == "com.oldsalt.peek"' --last 5m` |

## What Peek never does

- It never raises, moves, or interacts with windows — only reads pixels.
- It never sends data off your Mac. The MCP listener is bound to `127.0.0.1`.
- It never captures anything an agent asks for without your bearer token *and* (for unfamiliar apps) your explicit approval.
- It does not request Accessibility — ScreenCaptureKit composites occluded windows for us.
