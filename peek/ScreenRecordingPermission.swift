import CoreGraphics
import Foundation
import AppKit

enum ScreenRecordingPermission {
    /// True if this process already holds Screen Recording (TCC) consent.
    /// Non-prompting — safe to call on every menu open / refresh.
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system TCC prompt the first time it's called from this app.
    /// Returns the post-prompt state (true on instant grant; usually false on first
    /// call because the user hasn't acted yet — the real answer arrives on next launch).
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Deep link into System Settings → Privacy & Security → Screen Recording.
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
