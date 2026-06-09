import AppKit
import Foundation
import ScreenCaptureKit

struct DisplayInfo: Sendable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let isMain: Bool
}

/// ScreenCaptureKit-backed display enumeration and whole-display capture.
///
/// Sibling to `WindowCapture`. Whole-display capture has a wider privacy
/// surface than per-window (a notification, a 1Password panel, an email
/// preview can sit on any display), so the MCP layer gates `capture_display`
/// behind both managed policy (`ManagedPreferences.evaluateDisplayCapture`)
/// and a per-display approval prompt. Enumeration (`listDisplays`) leaks only
/// geometry + monitor names, so it isn't gated.
enum DisplayCapture {
    static func listDisplays() async throws -> [DisplayInfo] {
        let content = try await fetchContent()
        let names = displayNamesByID()
        return content.displays.map { makeDisplayInfo($0, names: names) }
    }

    /// Resolve a display id to its `DisplayInfo` without capturing — used to
    /// fetch the name before consulting the approval gate.
    static func resolveDisplay(id: CGDirectDisplayID) async throws -> DisplayInfo {
        let content = try await fetchContent()
        let names = displayNamesByID()
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw WindowCaptureError.displayNotFound(id)
        }
        return makeDisplayInfo(display, names: names)
    }

    /// Resolve a display by case-insensitive substring match against its
    /// localized name. Throws `.ambiguousDisplay` when more than one matches so
    /// the agent can re-ask by id; `.displayNotFound(0)` when none match.
    static func resolveDisplay(name: String) async throws -> DisplayInfo {
        let content = try await fetchContent()
        let names = displayNamesByID()
        let needle = name.lowercased()
        let matches = content.displays
            .map { makeDisplayInfo($0, names: names) }
            .filter { $0.name.lowercased().contains(needle) }
        switch matches.count {
        case 0:  throw WindowCaptureError.displayNotFound(0)
        case 1:  return matches[0]
        default: throw WindowCaptureError.ambiguousDisplay(matches.map(\.name))
        }
    }

    static func captureDisplay(id: CGDirectDisplayID) async throws -> Data {
        let content = try await fetchContent()
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw WindowCaptureError.displayNotFound(id)
        }
        return try await capture(display: display)
    }

    // MARK: - Private

    private static func fetchContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: false
            )
        } catch {
            throw WindowCaptureError.permissionDenied
        }
    }

    private static func capture(display: SCDisplay) async throws -> Data {
        // Empty exclusion set → composite every window on the display.
        let filter = SCContentFilter(display: display, excludingWindows: [])
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
        return try WindowCapture.png(from: cgImage)
    }

    /// Correlate `CGDirectDisplayID` → human-recognizable name via AppKit.
    /// `NSScreen.localizedName` is sandbox-safe (unlike `IODisplayCreateInfo
    /// Dictionary`, which we deliberately avoid — see TODO #11). A display
    /// present in SCK but absent from `NSScreen.screens` (rare) falls back to a
    /// generic name in `makeDisplayInfo`.
    private static func displayNamesByID() -> [CGDirectDisplayID: String] {
        var map: [CGDirectDisplayID: String] = [:]
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[key] as? NSNumber {
                map[CGDirectDisplayID(number.uint32Value)] = screen.localizedName
            }
        }
        return map
    }

    private static func makeDisplayInfo(
        _ display: SCDisplay,
        names: [CGDirectDisplayID: String]
    ) -> DisplayInfo {
        DisplayInfo(
            id: display.displayID,
            name: names[display.displayID] ?? "Display \(display.displayID)",
            frame: display.frame,
            isMain: display.displayID == CGMainDisplayID()
        )
    }
}
