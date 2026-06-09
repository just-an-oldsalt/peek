import Testing
import CoreGraphics
import Foundation
@testable import peek

@Test func windowCaptureErrorDescriptions() {
    #expect(WindowCaptureError.permissionDenied.description == "Screen Recording permission denied")
    #expect(WindowCaptureError.windowNotFound(42).description == "Window 42 not found")
    #expect(
        WindowCaptureError.appNotRunning("Calculator").description
            == "No running app with captureable windows matching 'Calculator'"
    )
    #expect(WindowCaptureError.encodingFailed.description == "Failed to encode capture as PNG")
    #expect(WindowCaptureError.policyDenied("nope").description == "nope")
    #expect(WindowCaptureError.displayNotFound(7).description == "Display 7 not found")
    #expect(
        WindowCaptureError.ambiguousDisplay(["Studio Display", "Studio Display (2)"]).description
            == "Ambiguous display name — matches Studio Display, Studio Display (2). Capture by id instead."
    )
}

@Test func displayInfoIsValueType() {
    let a = DisplayInfo(
        id: 1,
        name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        isMain: true
    )
    let b = a
    #expect(a == b)
    #expect(a.hashValue == b.hashValue)
}

@Test func windowInfoIsValueType() {
    let a = WindowInfo(
        id: 1,
        app: "Calculator",
        bundleID: "com.apple.calculator",
        title: "Calculator",
        bounds: CGRect(x: 0, y: 0, width: 320, height: 480),
        pid: 1234
    )
    let b = a
    #expect(a == b)
    #expect(a.hashValue == b.hashValue)
}

// Serialized: every case mutates the shared `ManagedPreferences.pathsProvider`
// global. Parallel scheduling lets two tests stomp on each other's plist
// override mid-evaluation, which surfaces as random failures.
@Suite(.serialized)
struct ManagedPolicyTests {
    @Test func defaultsToUserControlled() {
        withTempManagedPlist([:]) {
            #expect(
                ManagedPreferences.evaluate(bundleID: "com.apple.calculator", appName: "Calculator")
                    == .userControlled
            )
        }
    }

    @Test func denylistBlocksByBundle() {
        withTempManagedPlist(["deniedApps": ["com.apple.calculator"]]) {
            let decision = ManagedPreferences.evaluate(bundleID: "com.apple.calculator", appName: "Calculator")
            if case .denied(let reason) = decision {
                #expect(reason.contains("Calculator"))
            } else {
                Issue.record("expected denied, got \(decision)")
            }
        }
    }

    @Test func allowlistAdmitsMembersAndBlocksOthers() {
        withTempManagedPlist(["allowedApps": ["com.apple.calculator"]]) {
            #expect(
                ManagedPreferences.evaluate(bundleID: "com.apple.calculator", appName: "Calculator")
                    == .allowed
            )

            let blocked = ManagedPreferences.evaluate(bundleID: "com.apple.safari", appName: "Safari")
            if case .denied = blocked {} else {
                Issue.record("expected denied for Safari, got \(blocked)")
            }
        }
    }

    @Test func denylistWinsOverAllowlist() {
        withTempManagedPlist([
            "allowedApps": ["com.apple.calculator"],
            "deniedApps":  ["com.apple.calculator"],
        ]) {
            let decision = ManagedPreferences.evaluate(bundleID: "com.apple.calculator", appName: "Calculator")
            if case .denied = decision {} else {
                Issue.record("expected denied, got \(decision)")
            }
        }
    }

    // §0 tri-state: absent and managed-true both fall through to the per-display
    // prompt (.userControlled); only an explicit managed-false hard-denies.
    @Test func displayCaptureAbsentIsUserControlled() {
        withTempManagedPlist([:]) {
            #expect(ManagedPreferences.evaluateDisplayCapture() == .userControlled)
        }
    }

    @Test func displayCaptureManagedTrueIsUserControlled() {
        withTempManagedPlist(["allowScreenCapture": true]) {
            #expect(ManagedPreferences.evaluateDisplayCapture() == .userControlled)
        }
    }

    @Test func displayCaptureManagedFalseIsDenied() {
        withTempManagedPlist(["allowScreenCapture": false]) {
            if case .denied = ManagedPreferences.evaluateDisplayCapture() {} else {
                Issue.record("expected denied when allowScreenCapture=false")
            }
        }
    }
}

// DisplayApprovalStore mutates UserDefaults.standard under "trustedDisplaysV1".
// Serialized + save/restore so it doesn't race or pollute the real domain.
@MainActor
@Suite(.serialized)
struct DisplayApprovalStoreTests {
    private static let key = "trustedDisplaysV1"

    private func withCleanDefaults(_ body: (DisplayApprovalStore) -> Void) {
        let previous = UserDefaults.standard.data(forKey: Self.key)
        UserDefaults.standard.removeObject(forKey: Self.key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: Self.key) }
            else { UserDefaults.standard.removeObject(forKey: Self.key) }
        }
        body(DisplayApprovalStore())
    }

    @Test func addAndRevokeRoundTrip() {
        withCleanDefaults { store in
            #expect(!store.isAlwaysAllowed(name: "DELL U2720Q"))

            store.allowAlways(name: "DELL U2720Q")
            #expect(store.isAlwaysAllowed(name: "DELL U2720Q"))
            // Case-insensitive key.
            #expect(store.isAlwaysAllowed(name: "dell u2720q"))
            #expect(store.trusted.count == 1)

            // Persists across a fresh load of the same defaults.
            let reloaded = DisplayApprovalStore()
            #expect(reloaded.isAlwaysAllowed(name: "DELL U2720Q"))

            store.revoke(name: "DELL U2720Q")
            #expect(!store.isAlwaysAllowed(name: "DELL U2720Q"))
            #expect(store.trusted.isEmpty)
        }
    }

    @Test func revokeAllClears() {
        withCleanDefaults { store in
            store.allowAlways(name: "Built-in Retina Display")
            store.allowAlways(name: "LG UltraFine")
            #expect(store.trusted.count == 2)
            store.revokeAll()
            #expect(store.trusted.isEmpty)
        }
    }
}

private func withTempManagedPlist(_ values: [String: Any], body: () -> Void) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("peek-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let plist = dir.appendingPathComponent("com.oldsalt.peek.plist")
    (values as NSDictionary).write(to: plist, atomically: true)

    let previous = ManagedPreferences.pathsProvider
    ManagedPreferences.pathsProvider = { [plist.path] }
    defer {
        ManagedPreferences.pathsProvider = previous
        try? FileManager.default.removeItem(at: dir)
    }
    body()
}
