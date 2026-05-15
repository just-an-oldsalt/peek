# Peek

A macOS menu bar utility that hands captureable app windows to AI agents over a local MCP endpoint.

## Status

Bootstrap / pre-MVP. Builds an empty menu bar agent. ScreenCaptureKit harness, MCP server, and per-app trust UX land in subsequent tasks.

## Architectural template

Peek follows the same shape as [Niacin](https://github.com/just-an-oldsalt/niacin):

- Menu bar agent only (`LSUIElement = YES`, no Dock icon)
- macOS 14 Sonoma minimum
- App Sandbox on, hardened runtime on
- Only entitlement beyond defaults: `com.apple.security.network.server` (loopback MCP listener)
- Bundle ID `com.oldsalt.peek`, MCP port `11473` → Peek uses `11474`

## Build

1. Open `peek.xcodeproj` in Xcode
2. Set your development team in **Signing & Capabilities**
3. Build and run (`⌘R`)
