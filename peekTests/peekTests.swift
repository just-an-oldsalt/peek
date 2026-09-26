import Testing
import CoreGraphics
import Foundation
import ScreenCaptureKit
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

@Test func shareableContentErrorMapping() {
    let other = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
    let declined = SCStreamError(.userDeclined)

    // Without consent, any failure is a permission problem.
    guard case .permissionDenied = WindowCaptureError.fromShareableContent(other, granted: false) else {
        Issue.record("expected permissionDenied when not granted"); return
    }
    // An explicit TCC refusal is a permission problem even if preflight said yes.
    guard case .permissionDenied = WindowCaptureError.fromShareableContent(declined, granted: true) else {
        Issue.record("expected permissionDenied for userDeclined"); return
    }
    // Anything else surfaces the real error.
    let mapped = WindowCaptureError.fromShareableContent(other, granted: true)
    #expect(mapped.description == "Capture failed: boom")
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
        pid: 1234,
        isOnScreen: true
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

    // launchAtLogin is tri-state: absent leaves the first-run default in
    // charge, true/false are policy pins that suppress it.
    @Test func launchAtLoginAbsentIsUnmanaged() {
        withTempManagedPlist([:]) {
            #expect(ManagedPreferences.launchAtLogin == nil)
        }
    }

    @Test func launchAtLoginManagedTrue() {
        withTempManagedPlist(["launchAtLogin": true]) {
            #expect(ManagedPreferences.launchAtLogin == true)
        }
    }

    @Test func launchAtLoginManagedFalse() {
        withTempManagedPlist(["launchAtLogin": false]) {
            #expect(ManagedPreferences.launchAtLogin == false)
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

// Frames observed on macOS 27.0 with a single 2560×1440 display.
@Test func systemPlaceholderWindowsAreDropped() {
    let displays = [CGRect(x: 0, y: 0, width: 2560, height: 1440)]
    func junk(_ title: String, _ frame: CGRect, onScreen: Bool = false) -> Bool {
        WindowCapture.isSystemPlaceholder(title: title, frame: frame, isOnScreen: onScreen, displays: displays)
    }
    // Dropped.
    #expect(junk("", CGRect(x: 0, y: 940, width: 500, height: 500)))     // parked per-app placeholder
    #expect(junk("", CGRect(x: 0, y: 1376, width: 64, height: 64)))     // CursorUIViewService
    #expect(junk("", CGRect(x: 1150, y: 629, width: 64, height: 64), onScreen: true))
    #expect(junk("", CGRect(x: 0, y: 0, width: 2560, height: 68)))      // Firefox strip
    #expect(junk("", CGRect(x: 0, y: -44, width: 2560, height: 44)))    // Zed strip above the display
    #expect(junk("", CGRect(x: 0, y: 0, width: 2560, height: 30), onScreen: true))
    // Kept.
    #expect(!junk("", CGRect(x: 2236, y: 348, width: 586, height: 476)))  // hidden Music mini player
    #expect(!junk("", CGRect(x: 1192, y: 43, width: 1341, height: 1124))) // hidden Photos
    #expect(!junk("", CGRect(x: 0, y: 940, width: 500, height: 500), onScreen: true))
    #expect(!junk("Desktop", CGRect(x: 0, y: 940, width: 500, height: 500)))
    #expect(!junk("", CGRect(x: 99, y: 111, width: 1084, height: 139), onScreen: true)) // Chrome bar
}

@Test func windowRankingPrefersVisibleTitledLarge() {
    func w(_ title: String, _ size: CGFloat, onScreen: Bool) -> WindowInfo {
        WindowInfo(id: 1, app: "App", bundleID: nil, title: title,
                   bounds: CGRect(x: 0, y: 0, width: size, height: size), pid: 1, isOnScreen: onScreen)
    }
    #expect(w("", 100, onScreen: true).isPreferred(over: w("Doc", 900, onScreen: false)))
    #expect(w("Doc", 100, onScreen: true).isPreferred(over: w("", 900, onScreen: true)))
    #expect(w("Doc", 900, onScreen: true).isPreferred(over: w("Other", 100, onScreen: true)))
    #expect(!w("Doc", 500, onScreen: true).isPreferred(over: w("Other", 500, onScreen: true)))
}
