import Foundation
import CoreGraphics

@MainActor
final class PeekMCPDelegate: MCPDelegate {
    private let approvals: AppApprovalStore

    init(approvals: AppApprovalStore) {
        self.approvals = approvals
    }

    func mcpToolDefinitions() -> [JSONValue] {
        [
            .object([
                "name": .string("list_windows"),
                "description": .string("List captureable windows. Returns id, owning app, window title, and bounds. Optionally filter by app name or bundle identifier."),
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
                "description": .string("Capture a specific window by id (as returned by list_windows) and return its pixels as a PNG. Captures occluded windows without raising them."),
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
                "description": .string("Capture the frontmost captureable window of the named app and return its pixels as a PNG. Convenience for 'show me what's in <app>' without first listing."),
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
