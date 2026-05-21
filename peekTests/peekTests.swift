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
