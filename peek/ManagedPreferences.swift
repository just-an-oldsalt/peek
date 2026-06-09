import Foundation
import OSLog

private let log = Logger(subsystem: "com.oldsalt.peek", category: "managed-prefs")

// Reads MDM-managed preferences deployed by JAMF or any MDM solution.
// JAMF deploys the plist to: /Library/Managed Preferences/com.oldsalt.peek.plist
//
// We read the managed plists directly from disk rather than via
// CFPreferencesCopyAppValue. cfprefsd aggressively caches the managed domain
// and doesn't reliably invalidate on direct plist edits — it expects
// ingestion via mdmclient / `profiles install`. Reading from disk guarantees
// live changes are picked up.
struct ManagedPreferences {
    private static let bundleID = Bundle.main.bundleIdentifier ?? "com.oldsalt.peek"

    // Per-user managed plist takes precedence over system-wide, matching
    // CFPreferences's resolution order for the managed domain.
    // Exposed as a closure so tests can point it at temporary files.
    nonisolated(unsafe) static var pathsProvider: () -> [String] = {
        [
            "/Library/Managed Preferences/\(NSUserName())/\(bundleID).plist",
            "/Library/Managed Preferences/\(bundleID).plist",
        ]
    }

    private static func managedValue(_ key: String) -> Any? {
        for path in pathsProvider() {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard let dict = NSDictionary(contentsOfFile: path) else {
                log.error("failed to parse \(path, privacy: .public) — check XML syntax")
                continue
            }
            if let value = dict[key] {
                return value
            }
        }
        return nil
    }

    // Master kill switch — false disables the app entirely (menu shows a
    // policy-disabled state, MCP server refuses to start).
    static var isEnabled: Bool { bool("enabled") ?? true }

    // Whether the loopback MCP listener should be running. Managed value wins
    // over the user default; user-controlled default is true (Peek's primary
    // value prop is agent-driven capture).
    static var mcpServerEnabled: Bool? { bool("mcpServerEnabled") }

    static var resolvedMCPServerEnabled: Bool {
        if let managed = mcpServerEnabled { return managed }
        if UserDefaults.standard.object(forKey: "mcpServerEnabled") != nil {
            return UserDefaults.standard.bool(forKey: "mcpServerEnabled")
        }
        return true
    }

    // Restrict captureable apps to this bundle-ID allowlist. When non-nil
    // and non-empty, captures for apps outside the list are policy-denied
    // before the per-app approval gate ever sees them.
    static var allowedApps: [String]? { stringArray("allowedApps") }

    // Always-denied bundle IDs. Overrides both `allowedApps` and any user
    // trust decision. Useful for org-wide "never let an agent capture
    // 1Password / Signal / Slack".
    static var deniedApps: [String]? { stringArray("deniedApps") }

    // Whole-display capture (`capture_display`). Tri-state by design — see
    // `evaluateDisplayCapture()`. This raw accessor is kept for the Settings
    // "Managed by Organisation" disclosure; the actual gate is the evaluator.
    // Note: a missing key is *not* a denial here — unmanaged users fall through
    // to the per-display approval prompt (gate 2). Only an explicit managed
    // `false` is a hard policy denial.
    static var allowScreenCaptureManaged: Bool? { bool("allowScreenCapture") }

    // Strip window titles from `list_windows` output. Some titles leak
    // document names (e.g. "Q4 forecast.xlsx").
    static var redactWindowTitles: Bool { bool("redactWindowTitles") ?? false }

    // Remove Quit from the menu bar menu.
    static var disableQuit: Bool { bool("disableQuit") ?? false }

    // True only if the key is set in a managed plist — drives lock icons
    // on the corresponding Settings controls.
    static func isManaged(key: String) -> Bool {
        managedValue(key) != nil
    }

    // MARK: - Per-app trust evaluation

    enum AppPolicyDecision: Equatable {
        case allowed         // explicitly OK by policy — skip user prompt
        case denied(String)  // blocked by policy with a human-readable reason
        case userControlled  // policy says nothing; ask the user / cache
    }

    /// Resolve whether `bundleID` (and `appName` for messaging) is permitted
    /// by managed policy before the per-app approval cache is consulted.
    static func evaluate(bundleID: String?, appName: String) -> AppPolicyDecision {
        if let denied = deniedApps,
           let bundleID,
           denied.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) {
            return .denied("\(appName) is blocked by your organisation's policy")
        }
        if let allowed = allowedApps, !allowed.isEmpty {
            guard let bundleID,
                  allowed.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) else {
                return .denied("\(appName) is not on your organisation's allowlist")
            }
            return .allowed
        }
        return .userControlled
    }

    /// Resolve whether whole-display capture (`capture_display`) is permitted
    /// by managed policy before the per-display approval cache is consulted.
    ///
    /// Tri-state, deliberately mirroring `evaluate(bundleID:appName:)`:
    ///   - managed `allowScreenCapture = false` → hard policy denial.
    ///   - managed `allowScreenCapture = true`  → user-controlled (we still
    ///     fire the per-display prompt; whole-display capture is higher-surface
    ///     than per-window, so an admin enabling the capability is not the same
    ///     as the user consenting to a specific monitor).
    ///   - key absent (the common, unmanaged case) → user-controlled.
    ///
    /// `.allowed` is never returned — display capture always gets gate 2.
    static func evaluateDisplayCapture() -> AppPolicyDecision {
        if allowScreenCaptureManaged == false {
            return .denied("Whole-display capture is disabled by your organisation's policy")
        }
        return .userControlled
    }

    private static func bool(_ key: String) -> Bool? {
        guard let raw = managedValue(key) else { return nil }
        return (raw as? NSNumber)?.boolValue
    }

    private static func stringArray(_ key: String) -> [String]? {
        guard let raw = managedValue(key) as? [Any] else { return nil }
        let strings = raw.compactMap { $0 as? String }
        return strings.isEmpty ? nil : strings
    }
}
