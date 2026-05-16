import SwiftUI
import AppKit
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct PeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var menu = MenuModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContents(menu: menu)
        } label: {
            MenuBarLabel(menu: menu)
        }
        .menuBarExtraStyle(.menu)

        Window("About Peek", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var menu: MenuModel

    var body: some View {
        Image(systemName: menu.permissionGranted ? "viewfinder" : "viewfinder.slash")
    }
}

@MainActor
final class MenuModel: ObservableObject {
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

    private let server: MCPServer
    private let mcpDelegate = PeekMCPDelegate()

    init() {
        server = MCPServer()
        server.setDelegate(mcpDelegate)
        bootstrapMCP()
    }

    private func bootstrapMCP() {
        do {
            if try MCPTokenStore.currentToken() == nil {
                _ = try MCPTokenStore.generateAndStore()
            }
            mcpToken = try MCPTokenStore.currentToken()
        } catch {
            mcpError = "Token init failed: \(error.localizedDescription)"
            return
        }
        do {
            try server.start()
            mcpPort = server.actualPort
        } catch {
            mcpError = "MCP start failed: \(error.localizedDescription)"
        }
    }

    func copyMCPToken() {
        guard let token = mcpToken else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(token, forType: .string)
        status = "MCP token copied to clipboard"
    }

    func copyMCPConfig() {
        guard let token = mcpToken, let port = mcpPort else {
            status = "MCP config not ready"
            return
        }
        // Streamable-HTTP MCP config. Works directly with Claude Code and any
        // client that supports the HTTP transport. Claude Desktop today only
        // accepts the stdio transport in claude_desktop_config.json — see
        // TODO.md #10 for the proxy-bridge work needed to support it.
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
        status = "Config copied (Claude Code / HTTP-MCP clients)"
    }

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
    @ObservedObject var menu: MenuModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if !menu.permissionGranted {
                Text("Screen Recording permission required")
                Button("Grant Screen Recording…") {
                    menu.requestPermission()
                }
                Text("After granting, quit and relaunch Peek.")
            } else {
                Menu("Capture window to clipboard") {
                    if menu.apps.isEmpty {
                        Text(menu.isRefreshing ? "Loading…" : "No captureable windows")
                    } else {
                        ForEach(menu.apps) { entry in
                            Button(entry.name) {
                                Task { await menu.capture(entry) }
                            }
                        }
                    }
                }
            }

            if let status = menu.status {
                Divider()
                Text(status)
            }

            Divider()

            Section("MCP") {
                if let port = menu.mcpPort {
                    Text("Listening on 127.0.0.1:\(String(port))")
                } else if let err = menu.mcpError {
                    Text(err)
                } else {
                    Text("Starting…")
                }
                Button("Copy Claude Desktop config") { menu.copyMCPConfig() }
                    .disabled(menu.mcpToken == nil || menu.mcpPort == nil)
                Button("Copy MCP token") { menu.copyMCPToken() }
                    .disabled(menu.mcpToken == nil)
                Button("Test connection") {
                    Task { await menu.testMCPConnection() }
                }
                .disabled(menu.mcpToken == nil || menu.mcpPort == nil)
                Button("Regenerate token") { menu.regenerateMCPToken() }
            }

            Divider()

            Button("Refresh") {
                Task { await menu.refresh() }
            }

            Divider()

            Button("About Peek") {
                openWindow(id: "about")
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("Quit Peek") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .onAppear {
            Task { await menu.refresh() }
        }
    }
}
