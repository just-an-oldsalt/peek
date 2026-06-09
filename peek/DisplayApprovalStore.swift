import Foundation
import AppKit
import Combine
import OSLog

private let log = Logger(subsystem: "com.oldsalt.peek", category: "approval")
private let auditLog = Logger(subsystem: "com.oldsalt.peek", category: "audit")

// Per-display approval cache — sibling to AppApprovalStore (gate 2 for the
// `capture_display` MCP tool). Whole-display capture has a wider privacy
// surface than per-window, so it gets its own first-capture consent even when
// managed policy permits the capability.
//
// Keyed by the display's localized name (e.g. "DELL U2720Q"), lowercased.
// CGDirectDisplayID is unstable across reboots and EDID hashing needs IOKit we
// deliberately avoid under the sandbox (see TODO #11), so the human-recognizable
// name is the most stable sandbox-safe key — an external monitor unplugged and
// replugged keeps its trust.

/// Snapshot of a trusted display for Settings display.
struct TrustedDisplay: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let firstApprovedAt: Date
}

@MainActor
final class DisplayApprovalStore: ObservableObject {
    // Versioned key — same migration discipline as trustedAppsV1.
    private static let defaultsKey = "trustedDisplaysV1"

    private struct Entry: Codable {
        let displayName: String
        let firstApprovedAt: Date
    }

    @Published private(set) var trusted: [TrustedDisplay] = []

    private var entries: [String: Entry] = [:]

    init() { load() }

    func isAlwaysAllowed(name: String) -> Bool {
        entries[name.lowercased()] != nil
    }

    func allowAlways(name: String) {
        let key = name.lowercased()
        if entries[key] == nil {
            entries[key] = Entry(displayName: name, firstApprovedAt: Date())
            persist()
            auditLog.info("trusted display added: \(key, privacy: .private)")
        }
    }

    func revoke(name: String) {
        let key = name.lowercased()
        guard entries.removeValue(forKey: key) != nil else { return }
        persist()
        auditLog.info("trusted display revoked: \(key, privacy: .private)")
    }

    func revokeAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        persist()
        auditLog.info("trusted displays cleared")
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else {
            entries = [:]
            trusted = []
            return
        }
        do {
            entries = try JSONDecoder().decode([String: Entry].self, from: data)
            rebuildPublished()
        } catch {
            // Loud on the way down: don't silently drop the user's trust cache
            // on an unhandled schema change.
            log.error("trustedDisplaysV1 decode failed (\(error.localizedDescription, privacy: .public)) — keeping in-memory store empty but NOT overwriting the on-disk blob")
            entries = [:]
            trusted = []
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        } else {
            log.error("failed to encode trustedDisplays for UserDefaults")
        }
        rebuildPublished()
    }

    private func rebuildPublished() {
        trusted = entries
            .map { TrustedDisplay(name: $0.value.displayName, firstApprovedAt: $0.value.firstApprovedAt) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Prompt UI

/// Per-display capture approval prompt (gate 2). Shares the app-wide
/// `ApprovalPromptQueue` serializer so a window prompt and a display prompt
/// can't stack. Must be called on the main actor.
@MainActor
enum DisplayApprovalPrompt {
    static func ask(displayName: String) async -> AppApprovalDecision {
        let safeName = ApprovalPromptQueue.clamp(displayName)
        return await ApprovalPromptQueue.enqueue {
            ApprovalPromptQueue.runModal(
                messageText: "Allow agent to capture the \(safeName) display?",
                informativeText: """
                    An AI agent connected to Peek is asking to capture the entire \
                    \(safeName) display.

                    A whole-display capture can include anything on that screen — \
                    notifications, password panels, and previews from other apps.

                    Choose Allow Once to permit just this capture, or Always Allow \
                    to skip this prompt for \(safeName) in the future. You can revoke \
                    trusted displays from Peek → Settings → Trusted.
                    """
            )
        }
    }
}
