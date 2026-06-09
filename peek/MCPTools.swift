import Foundation
import CoreGraphics

@MainActor
final class PeekMCPDelegate: MCPDelegate {
    private let approvals: AppApprovalStore
    private let displayApprovals: DisplayApprovalStore

    init(approvals: AppApprovalStore, displayApprovals: DisplayApprovalStore) {
        self.approvals = approvals
        self.displayApprovals = displayApprovals
    }

    func mcpInstructions() -> String? {
        """
        Peek captures the pixels of on-screen app windows and whole displays on \
        this Mac and returns them as PNG images, so you can see what the user is \
        looking at without them screenshotting and pasting.

        All capture is local — the server is bound to loopback and nothing leaves \
        the device. Peek never moves, raises, or interacts with windows; it only reads pixels.

        Trust model: the first capture targeting a given app or display shows the \
        user a local "Allow Once / Always Allow / Deny" prompt. If the user denies \
        (or an organisation policy blocks it), the call returns an error — relay \
        that to the user rather than retrying in a loop.

        Typical flow: call list_windows or list_displays to discover targets, then \
        capture_window / capture_app / capture_display. Window titles and display \
        names (e.g. "Built-in Retina Display") are human-recognizable and safe to \
        reference back to the user.
        """
    }

    /// Annotations shared by every Peek tool: all are read-only screen reads —
    /// never destructive, safe to retry, loopback-only (no external world).
    /// Honored by clients on the 2025-03-26+ spec; older clients ignore them.
    private var readOnlyAnnotations: JSONValue {
        .object([
            "readOnlyHint": .bool(true),
            "destructiveHint": .bool(false),
            "idempotentHint": .bool(true),
            "openWorldHint": .bool(false),
        ])
    }

    func mcpToolDefinitions() -> [JSONValue] {
        [
            .object([
                "name": .string("list_windows"),
                "description": .string("List captureable windows. Returns id, owning app, window title, and bounds. Optionally filter by app name or bundle identifier. Read-only; does not trigger an approval prompt."),
                "annotations": readOnlyAnnotations,
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "app": .object([
                            "type": .string("string"),
                            "description": .string("Filter by application name or bundle identifier (case-insensitive). Omit to list all captureable windows."),
                        ]),
                    ]),
                ]),
            ]),
            .object([
                "name": .string("capture_window"),
                "description": .string("Capture a specific window by id (as returned by list_windows) and return its pixels as a PNG. Captures occluded windows without raising them. The first capture of a given app prompts the user (Allow Once / Always Allow / Deny); a denied capture returns an error — surface it, don't retry."),
                "annotations": readOnlyAnnotations,
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object([
                            "type": .string("integer"),
                            "description": .string("CGWindowID from list_windows."),
                        ]),
                    ]),
                    "required": .array([.string("id")]),
                ]),
            ]),
            .object([
                "name": .string("capture_app"),
                "description": .string("Capture the frontmost captureable window of the named app and return its pixels as a PNG. Convenience for 'show me what's in <app>' without first listing. The first capture of a given app prompts the user (Allow Once / Always Allow / Deny); a denied capture returns an error — surface it, don't retry."),
                "annotations": readOnlyAnnotations,
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Application name (e.g. \"Calculator\") or bundle identifier (e.g. \"com.apple.calculator\")."),
                        ]),
                    ]),
                    "required": .array([.string("name")]),
                ]),
            ]),
            .object([
                "name": .string("list_displays"),
                "description": .string("List connected displays (monitors) by human-recognizable name. Returns id, name (e.g. \"Built-in Retina Display\", \"DELL U2720Q\"), bounds, and whether it is the main display. Use to address a display by name in capture_display. Read-only; does not trigger an approval prompt."),
                "annotations": readOnlyAnnotations,
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ]),
            ]),
            .object([
                "name": .string("capture_display"),
                "description": .string("Capture an entire display (monitor) and return its pixels as a PNG. Identify the display by 'id' (from list_displays) or by 'name' (case-insensitive substring of the display's name). A whole-display capture composites every window on that screen, so it can include other apps' notifications and panels. The first capture of a given display prompts the user (Allow Once / Always Allow / Deny); a denied capture returns an error — surface it, don't retry."),
                "annotations": readOnlyAnnotations,
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object([
                            "type": .string("integer"),
                            "description": .string("CGDirectDisplayID from list_displays."),
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Display name or a case-insensitive substring of it (e.g. \"Dell\"). Ambiguous matches are rejected — use id."),
                        ]),
                    ]),
                ]),
            ]),
        ]
    }

    func mcpCallTool(name: String, args: [String: JSONValue]) async throws -> JSONValue {
        guard ManagedPreferences.isEnabled else {
            throw MCPToolError.internalError("Peek is disabled by organisation policy")
        }
        switch name {
        case "list_windows": return try await callListWindows(args: args)
        case "capture_window": return try await callCaptureWindow(args: args)
        case "capture_app": return try await callCaptureApp(args: args)
        case "list_displays": return try await callListDisplays(args: args)
        case "capture_display": return try await callCaptureDisplay(args: args)
        default: throw MCPToolError.unknownTool(name)
        }
    }

    private func callListWindows(args: [String: JSONValue]) async throws -> JSONValue {
        let app: String? = {
            if case .string(let s) = args["app"] ?? .null, !s.isEmpty { return s } else { return nil }
        }()
        let raw: [WindowInfo]
        do {
            raw = try await WindowCapture.listWindows(app: app)
        } catch let err as WindowCaptureError {
            throw MCPToolError.internalError(err.description)
        }

        // Hide windows the agent isn't allowed to capture under current
        // policy — both for privacy and to keep the agent from chasing
        // dead-ends. An unset bundleID can't be policy-matched, so we
        // surface it (user can still deny at the prompt).
        let redact = ManagedPreferences.redactWindowTitles
        let windows = raw.filter { w in
            switch ManagedPreferences.evaluate(bundleID: w.bundleID, appName: w.app) {
            case .denied: return false
            default:      return true
            }
        }.map { w -> WindowInfo in
            redact
                ? WindowInfo(id: w.id, app: w.app, bundleID: w.bundleID, title: "", bounds: w.bounds, pid: w.pid)
                : w
        }

        let text = windows.isEmpty
            ? "No captureable windows\(app.map { " for app '\($0)'" } ?? "")."
            : windows.map { w in
                "[\(w.id)] \(w.app) — \"\(w.title)\" \(Int(w.bounds.width))×\(Int(w.bounds.height))"
            }.joined(separator: "\n")

        let structured: JSONValue = .array(windows.map { w in
            .object([
                "id": .int(Int(w.id)),
                "app": .string(w.app),
                "bundle_id": w.bundleID.map { .string($0) } ?? .null,
                "title": .string(w.title),
                "bounds": .object([
                    "x": .double(Double(w.bounds.minX)),
                    "y": .double(Double(w.bounds.minY)),
                    "width": .double(Double(w.bounds.width)),
                    "height": .double(Double(w.bounds.height)),
                ]),
                "pid": .int(Int(w.pid)),
            ])
        })

        return .object([
            "content": .array([.object([
                "type": .string("text"),
                "text": .string(text),
            ])]),
            "structuredContent": .object(["windows": structured]),
        ])
    }

    private func callCaptureWindow(args: [String: JSONValue]) async throws -> JSONValue {
        guard let id = intArg(args["id"]) else {
            throw MCPToolError.invalidArguments("capture_window requires integer 'id'")
        }
        let info: WindowInfo
        do {
            info = try await WindowCapture.resolveWindow(id: CGWindowID(id))
        } catch let err as WindowCaptureError {
            throw MCPToolError.internalError(err.description)
        }
        try await requireApproval(for: info)
        return try await captureResolved(info)
    }

    private func callCaptureApp(args: [String: JSONValue]) async throws -> JSONValue {
        guard case .string(let name) = args["name"] ?? .null, !name.isEmpty else {
            throw MCPToolError.invalidArguments("capture_app requires non-empty 'name'")
        }
        let info: WindowInfo
        do {
            info = try await WindowCapture.resolveApp(name: name)
        } catch let err as WindowCaptureError {
            throw MCPToolError.internalError(err.description)
        }
        try await requireApproval(for: info)
        return try await captureResolved(info)
    }

    // MARK: - Display tools

    private func callListDisplays(args: [String: JSONValue]) async throws -> JSONValue {
        let displays: [DisplayInfo]
        do {
            displays = try await DisplayCapture.listDisplays()
        } catch let err as WindowCaptureError {
            throw MCPToolError.internalError(err.description)
        }

        let text = displays.isEmpty
            ? "No displays found."
            : displays.map { d in
                "[\(d.id)] \(d.name)\(d.isMain ? " (main)" : "") \(Int(d.frame.width))×\(Int(d.frame.height))"
            }.joined(separator: "\n")

        let structured: JSONValue = .array(displays.map { d in
            .object([
                "id": .int(Int(d.id)),
                "name": .string(d.name),
                "is_main": .bool(d.isMain),
                "frame": .object([
                    "x": .double(Double(d.frame.minX)),
                    "y": .double(Double(d.frame.minY)),
                    "width": .double(Double(d.frame.width)),
                    "height": .double(Double(d.frame.height)),
                ]),
            ])
        })

        return .object([
            "content": .array([.object([
                "type": .string("text"),
                "text": .string(text),
            ])]),
            "structuredContent": .object(["displays": structured]),
        ])
    }

    private func callCaptureDisplay(args: [String: JSONValue]) async throws -> JSONValue {
        let info: DisplayInfo
        do {
            if let id = intArg(args["id"]) {
                info = try await DisplayCapture.resolveDisplay(id: CGDirectDisplayID(id))
            } else if case .string(let name) = args["name"] ?? .null, !name.isEmpty {
                info = try await DisplayCapture.resolveDisplay(name: name)
            } else {
                throw MCPToolError.invalidArguments("capture_display requires 'id' (integer) or non-empty 'name'")
            }
        } catch let err as WindowCaptureError {
            // Ambiguous / not-found are argument problems the agent can correct.
            switch err {
            case .ambiguousDisplay, .displayNotFound:
                throw MCPToolError.invalidArguments(err.description)
            default:
                throw MCPToolError.internalError(err.description)
            }
        }

        try await requireDisplayApproval(for: info)

        let data: Data
        do {
            data = try await DisplayCapture.captureDisplay(id: info.id)
        } catch let err as WindowCaptureError {
            throw MCPToolError.internalError(err.description)
        }
        return imageResponse(png: data)
    }

    // MARK: - Approval + capture helpers

    /// Canonical policy-denial string. Don't differentiate between
    /// "in denylist" / "not in allowlist" / "bundle id missing under
    /// allowlist" — those differences let an agent probe the org's policy
    /// surface via the error channel.
    private static let policyDeniedMessage = "Capture blocked by your organisation's policy"

    private func requireApproval(for info: WindowInfo) async throws {
        switch ManagedPreferences.evaluate(bundleID: info.bundleID, appName: info.app) {
        case .denied:
            throw MCPToolError.internalError(Self.policyDeniedMessage)
        case .allowed:
            return
        case .userControlled:
            break
        }

        // Bundle ID is the cache key — apps without one (rare for real apps)
        // can't be remembered, so they re-prompt every call.
        if let bundleID = info.bundleID, approvals.isAlwaysAllowed(bundleID: bundleID) {
            return
        }

        let decision = await AppApprovalPrompt.ask(
            appName: info.app,
            bundleID: info.bundleID ?? "(unknown)"
        )
        switch decision {
        case .allowAlways:
            if let bundleID = info.bundleID {
                approvals.allowAlways(bundleID: bundleID, displayName: info.app)
            }
        case .allowOnce:
            break
        case .deny:
            throw MCPToolError.internalError("User denied capture of \(info.app)")
        }
    }

    /// Gate 2 for whole-display capture. Managed policy first
    /// (`evaluateDisplayCapture` — only an explicit managed `false` hard-denies),
    /// then the per-display approval cache + prompt. Always prompts on first
    /// capture of a display, even when policy permits — display capture is
    /// higher-surface than per-window.
    private func requireDisplayApproval(for info: DisplayInfo) async throws {
        switch ManagedPreferences.evaluateDisplayCapture() {
        case .denied:
            throw MCPToolError.internalError(Self.policyDeniedMessage)
        case .allowed:
            return
        case .userControlled:
            break
        }

        if displayApprovals.isAlwaysAllowed(name: info.name) {
            return
        }

        let decision = await DisplayApprovalPrompt.ask(displayName: info.name)
        switch decision {
        case .allowAlways:
            displayApprovals.allowAlways(name: info.name)
        case .allowOnce:
            break
        case .deny:
            throw MCPToolError.internalError("User denied capture of \(info.name) display")
        }
    }

    private func captureResolved(_ info: WindowInfo) async throws -> JSONValue {
        let data: Data
        do {
            data = try await WindowCapture.captureWindow(id: info.id)
        } catch let err as WindowCaptureError {
            throw MCPToolError.internalError(err.description)
        }
        return imageResponse(png: data)
    }

    private func imageResponse(png: Data) -> JSONValue {
        // Confirm the agent-driven capture in the menu bar, same as the
        // click-to-clipboard path. Both delegate and AppState are @MainActor.
        AppState.shared.flashCapture()
        let base64 = png.base64EncodedString()
        return .object([
            "content": .array([.object([
                "type": .string("image"),
                "data": .string(base64),
                "mimeType": .string("image/png"),
            ])]),
        ])
    }

    private func intArg(_ value: JSONValue?) -> Int? {
        guard let value else { return nil }
        switch value {
        case .int(let n): return n
        case .double(let d): return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }
}
