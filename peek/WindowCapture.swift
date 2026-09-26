import AppKit
import Foundation
import ScreenCaptureKit

nonisolated struct WindowInfo: Sendable, Hashable {
    let id: CGWindowID
    let app: String
    let bundleID: String?
    let title: String
    let bounds: CGRect
    let pid: pid_t
    let isOnScreen: Bool

    /// Ranking for "pick one window of this app": on-screen before off-screen,
    /// titled before untitled, then larger before smaller. Ties keep the
    /// earlier (ScreenCaptureKit) order.
    func isPreferred(over other: WindowInfo) -> Bool {
        if isOnScreen != other.isOnScreen { return isOnScreen }
        if title.isEmpty != other.title.isEmpty { return !title.isEmpty }
        return bounds.width * bounds.height > other.bounds.width * other.bounds.height
    }
}

enum WindowCaptureError: Error, CustomStringConvertible {
    case permissionDenied
    case windowNotFound(CGWindowID)
    case appNotRunning(String)
    case displayNotFound(CGDirectDisplayID)
    case ambiguousDisplay([String])
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
        case .displayNotFound(let id):
            return "Display \(id) not found"
        case .ambiguousDisplay(let names):
            return "Ambiguous display name — matches \(names.joined(separator: ", ")). Capture by id instead."
        case .captureFailed(let error):
            return "Capture failed: \(error.localizedDescription)"
        case .encodingFailed:
            return "Failed to encode capture as PNG"
        case .policyDenied(let reason):
            return reason
        }
    }

    /// Maps a failed `SCShareableContent` fetch. Only a genuine TCC refusal
    /// becomes `.permissionDenied`; anything else keeps the underlying error so
    /// an unrelated ScreenCaptureKit failure doesn't masquerade as a
    /// permissions problem.
    static func fromShareableContent(_ error: any Error, granted: Bool) -> WindowCaptureError {
        if !granted || (error as? SCStreamError)?.code == .userDeclined {
            return .permissionDenied
        }
        return .captureFailed(error)
    }
}

/// ScreenCaptureKit-backed window enumeration and single-window capture.
///
/// Windows are composited off-screen by `SCScreenshotManager` — never raised, moved, or
/// activated — so this stays inside the App Sandbox with no Accessibility entitlement.
enum WindowCapture {
    static func listWindows(app: String? = nil) async throws -> [WindowInfo] {
        let content = try await fetchContent()
        let displays = content.displays.map(\.frame)
        return content.windows
            .filter { isCaptureableWindow($0, matching: app, displays: displays) }
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

    /// Resolve the best captureable window matching `name` without
    /// capturing — used to fetch the bundle ID before the approval gate.
    static func resolveApp(name: String) async throws -> WindowInfo {
        let content = try await fetchContent()
        return makeWindowInfo(try bestWindow(in: content, matching: name))
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
        return try await capture(window: try bestWindow(in: content, matching: name))
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
            throw WindowCaptureError.fromShareableContent(error, granted: ScreenRecordingPermission.isGranted)
        }
    }

    /// The app's window to use for `capture_app` and the click-to-clipboard
    /// menu. `SCShareableContent` order isn't "frontmost", and the first match
    /// is often a system placeholder, so rank instead of taking `.first`.
    private static func bestWindow(in content: SCShareableContent, matching name: String) throws -> SCWindow {
        let displays = content.displays.map(\.frame)
        var best: (window: SCWindow, info: WindowInfo)?
        for window in content.windows where isCaptureableWindow(window, matching: name, displays: displays) {
            let info = makeWindowInfo(window)
            if best.map({ info.isPreferred(over: $0.info) }) ?? true {
                best = (window, info)
            }
        }
        guard let best else { throw WindowCaptureError.appNotRunning(name) }
        return best.window
    }

    /// Untitled layer-0 windows that exist for system bookkeeping rather than
    /// content (observed on macOS 27.0: dozens per session). None of them is
    /// worth handing to an agent:
    /// - tiny (≤ 64×64) cursor / drag / text-input service windows;
    /// - display-wide strips under 100pt tall — menu-bar tracking shadows,
    ///   sitting at or just above a display's top edge;
    /// - off-screen windows parked flush in a display's bottom-left corner
    ///   (the per-app 500×500 placeholders).
    /// Hidden or minimised real windows keep their last frame, so an untitled
    /// one (Photos, the Music mini player) still survives.
    nonisolated static func isSystemPlaceholder(title: String, frame: CGRect, isOnScreen: Bool, displays: [CGRect]) -> Bool {
        guard title.isEmpty else { return false }
        if frame.width <= 64, frame.height <= 64 { return true }
        if frame.height < 100, displays.contains(where: { frame.width >= $0.width }) { return true }
        if !isOnScreen, displays.contains(where: { frame.minX == $0.minX && frame.maxY == $0.maxY }) {
            return true
        }
        return false
    }

    private static func isCaptureableWindow(_ window: SCWindow, matching app: String?, displays: [CGRect]) -> Bool {
        guard let owning = window.owningApplication else { return false }
        guard window.windowLayer == 0 else { return false }
        guard window.frame.width > 0, window.frame.height > 0 else { return false }
        if isSystemPlaceholder(title: window.title ?? "", frame: window.frame,
                               isOnScreen: window.isOnScreen, displays: displays) {
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

    /// Shared PNG encoder — also used by `DisplayCapture`.
    static func png(from cgImage: CGImage) throws -> Data {
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
            pid: owning.map { $0.processID } ?? 0,
            isOnScreen: window.isOnScreen
        )
    }
}
