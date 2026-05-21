import AppKit
import Foundation
import ScreenCaptureKit

struct WindowInfo: Sendable, Hashable {
    let id: CGWindowID
    let app: String
    let bundleID: String?
    let title: String
    let bounds: CGRect
    let pid: pid_t
}

enum WindowCaptureError: Error, CustomStringConvertible {
    case permissionDenied
    case windowNotFound(CGWindowID)
    case appNotRunning(String)
    case captureFailed(any Error)
    case encodingFailed
    case policyDenied(String)

    var description: String {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission denied"
        case .windowNotFound(let id):
            return "Window \(id) not found"
        case .appNotRunning(let name):
            return "No running app with captureable windows matching '\(name)'"
        case .captureFailed(let error):
            return "Capture failed: \(error.localizedDescription)"
        case .encodingFailed:
            return "Failed to encode capture as PNG"
        case .policyDenied(let reason):
            return reason
        }
    }
}

/// ScreenCaptureKit-backed window enumeration and single-window capture.
///
/// Windows are composited off-screen by `SCScreenshotManager` — never raised, moved, or
/// activated — so this stays inside the App Sandbox with no Accessibility entitlement.
enum WindowCapture {
    static func listWindows(app: String? = nil) async throws -> [WindowInfo] {
        let content = try await fetchContent()
        return content.windows
            .filter { isCaptureableWindow($0, matching: app) }
            .map(makeWindowInfo)
    }

    /// Resolve a window id to its `WindowInfo` without capturing — used to
    /// fetch the bundle ID before consulting the approval gate.
    static func resolveWindow(id: CGWindowID) async throws -> WindowInfo {
        let content = try await fetchContent()
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw WindowCaptureError.windowNotFound(id)
        }
        return makeWindowInfo(window)
    }

    /// Resolve the frontmost captureable window matching `name` without
    /// capturing — used to fetch the bundle ID before the approval gate.
    static func resolveApp(name: String) async throws -> WindowInfo {
        let content = try await fetchContent()
        guard let frontmost = content.windows.first(where: { isCaptureableWindow($0, matching: name) }) else {
            throw WindowCaptureError.appNotRunning(name)
        }
        return makeWindowInfo(frontmost)
    }

    static func captureWindow(id: CGWindowID) async throws -> Data {
        let content = try await fetchContent()
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw WindowCaptureError.windowNotFound(id)
        }
        return try await capture(window: window)
    }

    static func captureApp(name: String) async throws -> Data {
        let content = try await fetchContent()
        guard let frontmost = content.windows.first(where: { isCaptureableWindow($0, matching: name) }) else {
            throw WindowCaptureError.appNotRunning(name)
        }
        return try await capture(window: frontmost)
    }

    // MARK: - Private

    private static func fetchContent() async throws -> SCShareableContent {
        do {
            // onScreenWindowsOnly: false → include occluded and off-screen windows so we
            // can capture minimized / hidden windows without raising them.
            return try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: false
            )
        } catch {
            throw WindowCaptureError.permissionDenied
        }
    }

    private static func isCaptureableWindow(_ window: SCWindow, matching app: String?) -> Bool {
        guard let owning = window.owningApplication else { return false }
        guard window.windowLayer == 0 else { return false }
        guard window.frame.width > 0, window.frame.height > 0 else { return false }
        // Drop the empty-titled menu-bar tracking shadows that the system
        // attaches to the active app (full screen width, flush to top, height
        // ≤ menu bar). They report windowLayer 0 and would otherwise z-order
        // ahead of the real window in capture_app.
        let title = window.title ?? ""
        if title.isEmpty,
           window.frame.minY == 0,
           window.frame.height < 50 {
            return false
        }
        guard let app, !app.isEmpty else { return true }
        let target = app.lowercased()
        return owning.applicationName.lowercased() == target
            || owning.bundleIdentifier.lowercased() == target
    }

    private static func capture(window: SCWindow) async throws -> Data {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(1, Int(filter.contentRect.width * scale))
        config.height = max(1, Int(filter.contentRect.height * scale))
        config.showsCursor = false

        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            throw WindowCaptureError.captureFailed(error)
        }
        return try png(from: cgImage)
    }

    private static func png(from cgImage: CGImage) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(width: cgImage.width, height: cgImage.height)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw WindowCaptureError.encodingFailed
        }
        return data
    }

    private static func makeWindowInfo(_ window: SCWindow) -> WindowInfo {
        let owning = window.owningApplication
        return WindowInfo(
            id: window.windowID,
            app: owning?.applicationName ?? "Unknown",
            bundleID: owning?.bundleIdentifier,
            title: window.title ?? "",
            bounds: window.frame,
            pid: owning.map { $0.processID } ?? 0
        )
    }
}
