import Testing
import CoreGraphics
@testable import peek

@Test func windowCaptureErrorDescriptions() {
    #expect(WindowCaptureError.permissionDenied.description == "Screen Recording permission denied")
    #expect(WindowCaptureError.windowNotFound(42).description == "Window 42 not found")
    #expect(
        WindowCaptureError.appNotRunning("Calculator").description
            == "No running app with captureable windows matching 'Calculator'"
    )
    #expect(WindowCaptureError.encodingFailed.description == "Failed to encode capture as PNG")
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
