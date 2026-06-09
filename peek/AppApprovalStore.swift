import Foundation
import AppKit
import Combine
import OSLog

private let log = Logger(subsystem: "com.oldsalt.peek", category: "approval")
private let auditLog = Logger(subsystem: "com.oldsalt.peek", category: "audit")

// Per-app approval cache (gate 2). MCP token is gate 1 — proves the request
// came from a paired client. This gate proves the user has consented to that
// client capturing this specific app at least once.
//
// Trust model:
//   - First MCP capture of bundle X with no cached decision → NSAlert with
//     three buttons: Deny / Allow Once / Always Allow.
//   - "Always Allow" persists in UserDefaults under the bundle ID.
//   - "Allow Once" proceeds but does not persist — next call re-prompts.
//   - "Deny" returns a policy error to the agent and does not persist —
//     keeping a denied bundle out of the agent's reach requires explicit
//     organisation policy (MDM `deniedApps`), not a one-click misclick.
//
// The human click-to-clipboard path bypasses this gate entirely: the click
// is the consent.

enum AppApprovalDecision: String, Codable {
    case allowOnce
    case allowAlways
    case deny
}

/// Snapshot of a trusted app for Settings display.
struct TrustedApp: Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    let displayName: String
    let firstApprovedAt: Date
}

@MainActor
final class AppApprovalStore: ObservableObject {
    // Versioned key so a future schema change can read-and-migrate the old
    // payload instead of silently wiping it (the `try?` decode would otherwise
    // mask a decode failure as "no entries").
    private static let defaultsKey = "trustedAppsV1"

    private struct Entry: Codable {
        let displayName: String
        let firstApprovedAt: Date
    }

    @Published private(set) var trusted: [TrustedApp] = []

    private var entries: [String: Entry] = [:]

    init() { load() }

    func isAlwaysAllowed(bundleID: String) -> Bool {
        entries[bundleID.lowercased()] != nil
    }

    func allowAlways(bundleID: String, displayName: String) {
        let key = bundleID.lowercased()
        if entries[key] == nil {
            entries[key] = Entry(displayName: displayName, firstApprovedAt: Date())
            persist()
            // .private privacy on the bundle id — the *set* of trusted apps
            // is user-private even if a single bundle id isn't a secret.
            auditLog.info("trusted bundle added: \(key, privacy: .private)")
        }
    }

    func revoke(bundleID: String) {
        let key = bundleID.lowercased()
        guard entries.removeValue(forKey: key) != nil else { return }
        persist()
        auditLog.info("trusted bundle revoked: \(key, privacy: .private)")
    }

    func revokeAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        persist()
        auditLog.info("trusted bundles cleared")
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
            // Loud on the way down: if a future schema change isn't handled
            // by a migration, we don't want to silently drop every user's
            // trust cache and re-prompt for every previously approved app.
            log.error("trustedAppsV1 decode failed (\(error.localizedDescription, privacy: .public)) — keeping in-memory store empty but NOT overwriting the on-disk blob")
            entries = [:]
            trusted = []
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        } else {
            log.error("failed to encode trustedApps for UserDefaults")
        }
        rebuildPublished()
    }

    private func rebuildPublished() {
        trusted = entries
            .map { TrustedApp(bundleID: $0.key, displayName: $0.value.displayName, firstApprovedAt: $0.value.firstApprovedAt) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

// MARK: - Prompt UI

/// Serializes capture-approval NSAlerts across the whole app. Each enqueued
/// prompt chains behind the previous in-flight one, so two MCP requests racing
/// for capture (a window and a display, or two different bundles) produce
/// sequential prompts rather than stacked NSAlerts the user must dismiss in the
/// right order. `runModal()` spins a nested run loop, which is why naive
/// `@MainActor` isolation alone is insufficient to enforce this serialization.
///
/// Shared by `AppApprovalPrompt` (per-app, gate 2) and `DisplayApprovalPrompt`
/// (per-display) — see `DisplayApprovalStore.swift`.
@MainActor
enum ApprovalPromptQueue {
    /// Tail of the prompt queue. Each new prompt chains behind this task's
    /// completion before showing its own modal, then becomes the new tail.
    private static var serializer: Task<Void, Never> = Task {}

    /// Hard upper bound on any displayed string. Sandbox doesn't prevent an app
    /// (or a monitor) from publishing a name the length of a novel; without a
    /// clamp, that would render an alert taller than the screen.
    static let maxDisplayChars = 120

    /// Enqueue a modal builder. `body` runs on the main actor once all prior
    /// prompts have resolved, and must call `alert.runModal()` itself.
    static func enqueue(_ body: @escaping @MainActor () -> AppApprovalDecision) async -> AppApprovalDecision {
        let predecessor = serializer
        let mine = Task { @MainActor () -> AppApprovalDecision in
            _ = await predecessor.value
            return body()
        }
        serializer = Task { @MainActor in _ = await mine.value }
        return await mine.value
    }

    static func clamp(_ s: String) -> String {
        s.count <= maxDisplayChars ? s : String(s.prefix(maxDisplayChars)) + "…"
    }

    /// Builds and runs a three-button (Deny / Allow Once / Always Allow) alert.
    /// Caller supplies the copy; this owns the button mapping + activation.
    static func runModal(messageText: String, informativeText: String) -> AppApprovalDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Always Allow")

        // LSUIElement apps don't surface alerts in front of the foreground
        // app by default — activate so the user actually sees the prompt.
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .deny
        case .alertSecondButtonReturn: return .allowOnce
        case .alertThirdButtonReturn:  return .allowAlways
        default:                       return .deny
        }
    }
}

/// Per-app capture approval prompt (gate 2). Must be called on the main actor.
@MainActor
enum AppApprovalPrompt {
    static func ask(appName: String, bundleID: String) async -> AppApprovalDecision {
        let safeName = ApprovalPromptQueue.clamp(appName)
        let safeBundle = ApprovalPromptQueue.clamp(bundleID)
        return await ApprovalPromptQueue.enqueue {
            ApprovalPromptQueue.runModal(
                messageText: "Allow agent to capture \(safeName)?",
                informativeText: """
                    An AI agent connected to Peek is asking to capture the contents \
                    of \(safeName).

                    Bundle ID: \(safeBundle)

                    Choose Allow Once to permit just this capture, or Always Allow \
                    to skip this prompt for \(safeName) in the future. You can revoke \
                    trusted apps from Peek → Settings → Trusted.
                    """
            )
        }
    }
}
