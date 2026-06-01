import SwiftUI
import AppKit
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    private var welcomeController: WelcomeWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Peek is an LSUIElement (menu-bar-only) app, so its only launch-time
        // UI is the MenuBarExtra icon — which a reviewer can miss when it's
        // pushed under the notch or a crowded menu bar (App Review 2.1a).
        // Show a welcome window on first launch, and whenever Screen Recording
        // hasn't been granted yet (the app can't capture without it), so there
        // is always a visible window on launch.
        let key = "com.oldsalt.peek.hasShownWelcome"
        let defaults = UserDefaults.standard
        let firstLaunch = !defaults.bool(forKey: key)
        guard firstLaunch || !ScreenRecordingPermission.isGranted else { return }
        defaults.set(true, forKey: key)
        // Defer out of the launch display cycle. Creating/hosting the window
        // synchronously here throws inside AppKit's first Auto Layout pass
        // (EXC_BREAKPOINT via -[NSApplication _crashOnException:]); running it
        // on the next main-loop turn lets the launch transaction finish first.
        DispatchQueue.main.async { [weak self] in
            self?.showWelcome()
        }
    }

    func showWelcome() {
        if welcomeController == nil {
            welcomeController = WelcomeWindowController()
        }
        welcomeController?.show()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Granting Screen Recording happens in System Settings; returning to
        // Peek afterwards reactivates the app. Re-read consent here so the UI
        // updates on its own. Non-prompting and a no-op when nothing changed.
        Task { await AppState.shared.refreshPermission() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct PeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContents(app: app)
        } label: {
            MenuBarLabel(app: app)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(app)
                .environmentObject(app.approvals)
        }

        Window("About Peek", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var app: AppState

    var body: some View {
        // `viewfinder.slash` is not a real SF Symbol, so it renders blank —
        // which made the menu bar icon invisible whenever Screen Recording
        // wasn't granted (e.g. a fresh install). That blank icon was the root
        // cause of the App Review 2.1a "no UI on launch" rejection.
        Image(systemName: app.permissionGranted ? "viewfinder" : "viewfinder.trianglebadge.exclamationmark")
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    struct AppEntry: Identifiable, Hashable {
        let id: pid_t
        let name: String
        let windowID: CGWindowID
        let title: String
    }

    @Published private(set) var apps: [AppEntry] = []
    @Published private(set) var status: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var permissionGranted = ScreenRecordingPermission.isGranted

    @Published private(set) var mcpPort: UInt16?
    @Published private(set) var mcpToken: String?
    @Published private(set) var mcpError: String?
    @Published private(set) var mcpRunning = false

    let approvals = AppApprovalStore()
    private let server: MCPServer
    private let mcpDelegate: PeekMCPDelegate

    private init() {
        let approvals = self.approvals
        let delegate = PeekMCPDelegate(approvals: approvals)
        self.mcpDelegate = delegate
        self.server = MCPServer()
        server.setDelegate(delegate)
        bootstrapMCP()
    }

    private func bootstrapMCP() {
        guard ManagedPreferences.isEnabled else {
            mcpError = "Peek is disabled by organisation policy"
            return
        }
        do {
            if try MCPTokenStore.currentToken() == nil {
                _ = try MCPTokenStore.generateAndStore()
            }
            mcpToken = try MCPTokenStore.currentToken()
        } catch {
            mcpError = "Token init failed: \(error.localizedDescription)"
            return
        }
        startServerIfPolicyAllows()
    }

    /// Starts or stops the MCP server to match `ManagedPreferences.resolvedMCPServerEnabled`.
    /// Called from `bootstrapMCP()`, from the Settings toggle, and on policy reload.
    func startServerIfPolicyAllows() {
        let wantRunning = ManagedPreferences.isEnabled && ManagedPreferences.resolvedMCPServerEnabled
        if wantRunning, !server.isRunning {
            do {
                try server.start()
                mcpPort = server.actualPort
                mcpRunning = true
                mcpError = nil
            } catch {
                mcpError = "MCP start failed: \(error.localizedDescription)"
                mcpRunning = false
            }
        } else if !wantRunning, server.isRunning {
            server.stop()
            mcpPort = nil
            mcpRunning = false
        }
    }

    func copyMCPToken() {
        guard let token = mcpToken else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(token, forType: .string)
        status = "MCP token copied to clipboard"
    }

    /// Streamable-HTTP MCP config — works directly with Claude Code, Cursor,
    /// and other clients that support the HTTP transport.
    func copyClaudeCodeConfig() {
        guard let token = mcpToken, let port = mcpPort else {
            status = "MCP config not ready"
            return
        }
        let snippet = """
        {
          "mcpServers": {
            "peek": {
              "url": "http://127.0.0.1:\(port)",
              "headers": {
                "Authorization": "Bearer \(token)"
              }
            }
          }
        }
        """
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(snippet, forType: .string)
        status = "Config copied for Claude Code"
    }

    /// stdio-via-mcp-remote bridge — required for Claude Desktop, which
    /// doesn't yet accept the streamable-HTTP `url` shape. Pinned version
    /// avoids drift; bump in lockstep with verified-good releases.
    func copyClaudeDesktopConfig() {
        guard let token = mcpToken, let port = mcpPort else {
            status = "MCP config not ready"
            return
        }
        let snippet = """
        {
          "mcpServers": {
            "peek": {
              "command": "npx",
              "args": [
                "-y",
                "mcp-remote@\(Self.mcpRemoteVersionPin)",
                "http://127.0.0.1:\(port)/",
                "--allow-http",
                "--transport",
                "http-only",
                "--header",
                "Authorization: Bearer \(token)"
              ]
            }
          }
        }
        """
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(snippet, forType: .string)
        status = "Config copied for Claude Desktop"
    }

    /// Pinned `mcp-remote` version used by the Claude Desktop config snippet.
    /// Claude Desktop fetches and runs this via `npx -y` on every launch, so
    /// drift is observable to the user and reviewable in a security audit.
    static let mcpRemoteVersionPin = "0.1.38"

    func regenerateMCPToken() {
        do {
            mcpToken = try MCPTokenStore.generateAndStore()
            status = "MCP token rotated — update your client config"
        } catch {
            status = "Token rotation failed: \(error.localizedDescription)"
        }
    }

    func testMCPConnection() async {
        guard let token = mcpToken, let port = mcpPort else {
            status = "Test failed: no token or port"
            return
        }
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8)
        let request = HTTPRequest(
            method: "POST",
            path: "/",
            headers: [
                "host": "127.0.0.1:\(port)",
                "authorization": "Bearer \(token)",
                "content-type": "application/json",
            ],
            body: body
        )
        let response = await server.handle(request: request)
        let bodyText = String(data: response.body, encoding: .utf8) ?? ""
        if response.status == 200, bodyText.contains("\"name\":\"peek\"") {
            status = "MCP test OK — server responded with peek/\(serverVersion(from: bodyText))"
        } else {
            status = "MCP test failed: HTTP \(response.status) — \(bodyText.prefix(120))"
        }
    }

    private func serverVersion(from initBody: String) -> String {
        guard let range = initBody.range(of: #""version":""#) else { return "?" }
        let tail = initBody[range.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return "?" }
        return String(tail[..<end])
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        permissionGranted = ScreenRecordingPermission.isGranted
        guard permissionGranted else {
            apps = []
            status = nil
            return
        }
        do {
            let windows = try await WindowCapture.listWindows()
            var seen = Set<pid_t>()
            var grouped: [AppEntry] = []
            for w in windows where seen.insert(w.pid).inserted {
                grouped.append(.init(id: w.pid, name: w.app, windowID: w.id, title: w.title))
            }
            apps = grouped.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            status = apps.isEmpty ? "No captureable windows" : nil
        } catch {
            apps = []
            status = String(describing: error)
        }
    }

    /// Re-reads Screen Recording consent without enumerating windows unless the
    /// state actually changed. Cheap and non-prompting, so it's safe to call on
    /// every app activation — this is what lets the menu-bar icon, menu, and
    /// Welcome window reflect a grant the user just made in System Settings
    /// without requiring a manual Refresh.
    func refreshPermission() async {
        let granted = ScreenRecordingPermission.isGranted
        guard granted != permissionGranted else { return }
        permissionGranted = granted
        if granted {
            await refresh()
        } else {
            apps = []
            status = nil
        }
    }

    func requestPermission() {
        ScreenRecordingPermission.request()
        ScreenRecordingPermission.openSystemSettings()
    }

    func capture(_ entry: AppEntry) async {
        do {
            let data = try await WindowCapture.captureWindow(id: entry.windowID)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(data, forType: .png)
            status = "Copied \(entry.name) (\(data.count / 1024) KB)"
        } catch {
            status = "Capture failed: \(error)"
        }
    }
}

private struct MenuContents: View {
    @ObservedObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if !app.permissionGranted {
                Text("Peek needs Screen Recording access to capture windows.")
                Button("Continue") {
                    app.requestPermission()
                }
                Text("Peek detects the grant automatically — relaunch only if it doesn't.")
            } else {
                Menu("Capture window to clipboard") {
                    if app.apps.isEmpty {
                        Text(app.isRefreshing ? "Loading…" : "No captureable windows")
                    } else {
                        ForEach(app.apps) { entry in
                            Button(entry.name) {
                                Task { await app.capture(entry) }
                            }
                        }
                    }
                }
            }

            if let status = app.status {
                Divider()
                Text(status)
            }

            Divider()

            Section("MCP") {
                if !ManagedPreferences.isEnabled {
                    Text("Disabled by organisation policy")
                } else if app.mcpRunning, let port = app.mcpPort {
                    Text("Listening on 127.0.0.1:\(String(port))")
                } else if let err = app.mcpError {
                    Text(err)
                } else if !ManagedPreferences.resolvedMCPServerEnabled {
                    Text("MCP server disabled — enable in Settings")
                } else {
                    Text("Starting…")
                }
            }

            Divider()

            Button("Settings…") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",")

            Button("Refresh") {
                Task { await app.refresh() }
            }

            Divider()

            Button("About Peek") {
                openWindow(id: "about")
                NSApp.activate(ignoringOtherApps: true)
            }

            if !ManagedPreferences.disableQuit {
                Button("Quit Peek") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .onAppear {
            Task { await app.refresh() }
        }
    }
}

// First-launch onboarding window. Hosted in an explicit AppKit NSWindow rather
// than a SwiftUI scene because it is shown from `applicationDidFinishLaunching`,
// where `openWindow` isn't available and SwiftUI scene timing is unreliable.
@MainActor
final class WelcomeWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: WelcomeView { [weak self] in
                self?.window?.close()
            })
            hosting.sizingOptions = [.preferredContentSize]
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 460),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = "Welcome to Peek"
            w.contentViewController = hosting
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

private struct WelcomeView: View {
    let onDismiss: () -> Void
    // Observe the shared state rather than snapshotting consent on init, so the
    // window flips from "needs permission" to "enabled" live when the user grants
    // it in System Settings and returns (see AppDelegate.applicationDidBecomeActive).
    @ObservedObject private var app = AppState.shared

    private var appIcon: NSImage {
        NSRunningApplication.current.icon ?? NSApp.applicationIconImage
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 72, height: 72)

            Text("Welcome to Peek")
                .font(.title2)
                .fontWeight(.semibold)

            (Text("Peek lives in your menu bar. Look for the ")
                + Text(Image(systemName: "viewfinder"))
                + Text(" icon near the clock, top-right of your screen — click it to capture any window or open Settings."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            permissionSection

            Text("Peek also runs a local, bearer-authenticated MCP server on 127.0.0.1 so AI agents can request a window capture on demand. Manage it under Settings → MCP.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Link("Support", destination: URL(string: "https://peek.dort.zone/support")!)
                Spacer()
                Button("Get Started") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 380)
    }

    @ViewBuilder
    private var permissionSection: some View {
        if app.permissionGranted {
            Label("Screen Recording enabled", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        } else {
            VStack(spacing: 8) {
                Text("Peek needs Screen Recording permission to capture windows.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Continue") {
                    AppState.shared.requestPermission()
                }
            }
        }
    }
}
