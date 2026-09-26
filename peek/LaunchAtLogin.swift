import Foundation
import OSLog
import ServiceManagement

private let log = Logger(subsystem: "com.oldsalt.peek", category: "launch-at-login")

/// Launch-at-login via `SMAppService.mainApp` (macOS 13+).
///
/// Sandbox-compatible and needs no login-item helper target and no extra
/// entitlement — the main app registers itself as a login item.
///
/// Ported from Niacin's sibling app dixmix. Peek wants this more than either:
/// the MCP listener only answers while the app is running, so an agent calling
/// `peek.capture_window` on a fresh boot fails unless Peek came up with the
/// session.
///
/// **Peek never registers itself.** App Review 2.4.5(iii) treats a login item
/// the app adds on its own as auto-launching without user consent — Peek 1.2
/// build 7 was rejected for exactly that. Registration only ever happens from
/// an explicit user action (the Welcome window tick, or the Settings toggle)
/// or from an MDM pin set by the device owner.
enum LaunchAtLogin {
    /// True when the process is hosting a test bundle.
    ///
    /// `peekTests` runs with peek.app as its test host, so the real app's
    /// startup path executes during `xcodebuild test`. Without this, every
    /// test run would enrol the developer's own machine in a login item
    /// pointing at the DerivedData build. Guards the MDM-enforcement path in
    /// `AppState.bootstrapLaunchAtLogin()`.
    static var isRunningUnderTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// Whether the app is currently registered to launch at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register or unregister the main app as a login item. No-op if it is
    /// already in the desired state.
    static func set(_ on: Bool) throws {
        let service = SMAppService.mainApp
        if on {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            switch service.status {
            case .notRegistered, .notFound:
                return   // already off
            default:
                try service.unregister()
            }
        }
    }

}
