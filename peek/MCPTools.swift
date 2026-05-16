import Foundation
import CoreGraphics

@MainActor
final class PeekMCPDelegate: MCPDelegate {
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
        let windows: [WindowInfo]
        do {
            windows = try await WindowCapture.listWindows(app: app)
        } catch let err as WindowCaptureError {
            throw MCPToolError.internalError(err.description)
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
        let data: Data
        do {
            data = try await WindowCapture.captureWindow(id: CGWindowID(id))
        } catch let err as WindowCaptureError {
            throw MCPToolError.internalError(err.description)
        }
        return imageResponse(png: data)
    }

    private func callCaptureApp(args: [String: JSONValue]) async throws -> JSONValue {
        guard case .string(let name) = args["name"] ?? .null, !name.isEmpty else {
            throw MCPToolError.invalidArguments("capture_app requires non-empty 'name'")
        }
        let data: Data
        do {
            data = try await WindowCapture.captureApp(name: name)
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
