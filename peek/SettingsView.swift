import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var approvals: AppApprovalStore
    @EnvironmentObject private var displayApprovals: DisplayApprovalStore

    @AppStorage("mcpServerEnabled") private var mcpServerEnabledUserDefault: Bool = true

    @State private var selectedTab: SettingsTab = .mcp

    enum SettingsTab: Hashable { case mcp, permissions, trusted }

    var body: some View {
        TabView(selection: $selectedTab) {
            McpSettingsTab(
                app: app,
                mcpServerEnabled: $mcpServerEnabledUserDefault
            )
            .tabItem { Label("MCP", systemImage: "bolt.horizontal") }
            .tag(SettingsTab.mcp)

            PermissionsTab(app: app)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(SettingsTab.permissions)

            TrustedTab(approvals: approvals, displayApprovals: displayApprovals)
                .tabItem { Label("Trusted", systemImage: "checkmark.shield") }
                .tag(SettingsTab.trusted)
        }
        .frame(width: 480, height: 460)
    }
}

// MARK: - MCP tab

private struct McpSettingsTab: View {
    @ObservedObject var app: AppState
    @Binding var mcpServerEnabled: Bool
    @State private var copiedFlash: String?

    var body: some View {
        Form {
            Section("MCP Server") {
                ManagedToggle(
                    title: "Run local MCP server",
                    isOn: $mcpServerEnabled,
                    managed: ManagedPreferences.mcpServerEnabled
                )
                .onChange(of: mcpServerEnabled) { _, _ in
                    app.startServerIfPolicyAllows()
                }

                if app.mcpRunning, let port = app.mcpPort {
                    Label("Listening on http://127.0.0.1:\(String(port))",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout.monospaced())
                } else if let err = app.mcpError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if !ManagedPreferences.resolvedMCPServerEnabled {
                    Label("MCP server disabled.", systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Starting…", systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Client Configuration") {
                Text("Copy a config snippet and paste it into your AI client to connect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(copiedFlash == "code" ? "Copied!" : "Copy Claude Code config") {
                        app.copyClaudeCodeConfig()
                        flash("code")
                    }
                    Button(copiedFlash == "desktop" ? "Copied!" : "Copy Claude Desktop config") {
                        app.copyClaudeDesktopConfig()
                        flash("desktop")
                    }
                }
                .disabled(app.mcpToken == nil || app.mcpPort == nil)

                Button("Save .mcp.json to a project…") {
                    app.saveClaudeCodeConfigFile()
                }
                .disabled(app.mcpToken == nil || app.mcpPort == nil)

                Text("Claude Desktop uses a pinned `mcp-remote@\(AppState.mcpRemoteVersionPin)` bridge fetched via npx. Claude Code reads the loopback URL directly, or from a `.mcp.json` in a project folder. That file holds your token — keep it out of version control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Bearer Token") {
                HStack {
                    Button(copiedFlash == "token" ? "Copied!" : "Copy MCP token") {
                        app.copyMCPToken()
                        flash("token")
                    }
                    .disabled(app.mcpToken == nil)

                    Button("Rotate token") {
                        app.regenerateMCPToken()
                    }

                    Button("Test connection") {
                        Task { await app.testMCPConnection() }
                    }
                    .disabled(app.mcpToken == nil || app.mcpPort == nil)
                }

                Text("Rotating invalidates the existing token. Update every client config after rotating.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let status = app.status {
                Section { Text(status).font(.callout).foregroundStyle(.secondary) }
            }

            if hasManagedPolicies {
                Section("Managed by Organisation") {
                    if !ManagedPreferences.isEnabled {
                        PolicyRow("Peek disabled by IT policy", icon: "xmark.circle.fill", tint: .red)
                    }
                    if ManagedPreferences.mcpServerEnabled != nil {
                        PolicyRow("MCP server toggle is managed", icon: "lock.fill", tint: .orange)
                    }
                    if let allowed = ManagedPreferences.allowedApps {
                        PolicyRow("Capture allowlist (\(allowed.count) bundle IDs)",
                                  icon: "checklist", tint: .secondary)
                    }
                    if let denied = ManagedPreferences.deniedApps {
                        PolicyRow("Capture denylist (\(denied.count) bundle IDs)",
                                  icon: "nosign", tint: .secondary)
                    }
                    if ManagedPreferences.allowScreenCaptureManaged == false {
                        PolicyRow("Whole-display capture disabled by policy",
                                  icon: "display.trianglebadge.exclamationmark", tint: .orange)
                    }
                    if ManagedPreferences.redactWindowTitles {
                        PolicyRow("Window titles redacted in tool output",
                                  icon: "eye.slash", tint: .secondary)
                    }
                    if ManagedPreferences.disableQuit {
                        PolicyRow("Quit disabled by policy", icon: "lock.fill", tint: .orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 4)
    }

    private var hasManagedPolicies: Bool {
        !ManagedPreferences.isEnabled
            || ManagedPreferences.mcpServerEnabled != nil
            || ManagedPreferences.allowedApps != nil
            || ManagedPreferences.deniedApps != nil
            || ManagedPreferences.allowScreenCaptureManaged == false
            || ManagedPreferences.redactWindowTitles
            || ManagedPreferences.disableQuit
    }

    private func flash(_ key: String) {
        copiedFlash = key
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if copiedFlash == key { copiedFlash = nil }
        }
    }
}

// MARK: - Permissions tab

private struct PermissionsTab: View {
    @ObservedObject var app: AppState

    var body: some View {
        Form {
            Section("Screen Recording") {
                if app.permissionGranted {
                    Label("Granted — Peek can read window pixels.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Not granted — Peek cannot capture windows yet.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Open System Settings…") {
                        ScreenRecordingPermission.openSystemSettings()
                    }
                    Text("After enabling Peek in Screen Recording, quit and relaunch the app for the grant to take effect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Refresh") {
                    Task { await app.refresh() }
                }
                .controlSize(.small)
            }

            Section("What Peek Reads") {
                Text("""
                    Peek uses ScreenCaptureKit to read the pixels of windows you explicitly ask it to capture. \
                    It never raises, moves, or interacts with windows. It does not require Accessibility access.

                    The local MCP listener is bound to 127.0.0.1 only — nothing leaves your device.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 4)
    }
}

// MARK: - Trusted tab (apps + displays)

private struct TrustedTab: View {
    @ObservedObject var approvals: AppApprovalStore
    @ObservedObject var displayApprovals: DisplayApprovalStore

    enum Kind: Hashable { case apps, displays }
    @State private var kind: Kind = .apps

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $kind) {
                Text("Apps").tag(Kind.apps)
                Text("Displays").tag(Kind.displays)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 4)

            switch kind {
            case .apps:     TrustedAppsList(approvals: approvals)
            case .displays: TrustedDisplaysList(displayApprovals: displayApprovals)
            }

            if ManagedPreferences.allowScreenCaptureManaged == false {
                Divider()
                Label("Whole-display capture is disabled by your organisation's policy",
                      systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding([.horizontal, .bottom], 16)
                    .padding(.top, 8)
            }
        }
    }
}

private struct TrustedAppsList: View {
    @ObservedObject var approvals: AppApprovalStore
    @State private var selection: TrustedApp.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Agents can capture these apps without re-prompting. Approvals are added when you tap **Always Allow** on a capture prompt.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding([.horizontal], 16)
                .padding(.vertical, 8)

            if approvals.trusted.isEmpty {
                ContentUnavailableView(
                    "No Trusted Apps",
                    systemImage: "checkmark.shield",
                    description: Text("Apps you grant **Always Allow** will appear here.")
                )
                .padding()
            } else {
                Table(approvals.trusted, selection: $selection) {
                    TableColumn("App") { entry in
                        VStack(alignment: .leading) {
                            Text(entry.displayName)
                            Text(entry.bundleID)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    TableColumn("Approved") { entry in
                        Text(entry.firstApprovedAt, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 100)
                }
                .padding(.horizontal, 16)
            }

            HStack {
                Button("Revoke", role: .destructive) {
                    if let id = selection { approvals.revoke(bundleID: id) }
                    selection = nil
                }
                .disabled(selection == nil)

                Spacer()

                Button("Revoke All") {
                    approvals.revokeAll()
                    selection = nil
                }
                .disabled(approvals.trusted.isEmpty)
            }
            .padding(16)
        }
    }
}

private struct TrustedDisplaysList: View {
    @ObservedObject var displayApprovals: DisplayApprovalStore
    @State private var selection: TrustedDisplay.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Agents can capture these whole displays without re-prompting. Approvals are added when you tap **Always Allow** on a display-capture prompt.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding([.horizontal], 16)
                .padding(.vertical, 8)

            if displayApprovals.trusted.isEmpty {
                ContentUnavailableView(
                    "No Trusted Displays",
                    systemImage: "display",
                    description: Text("Displays you grant **Always Allow** will appear here.")
                )
                .padding()
            } else {
                Table(displayApprovals.trusted, selection: $selection) {
                    TableColumn("Display") { entry in
                        Text(entry.name)
                    }
                    TableColumn("Approved") { entry in
                        Text(entry.firstApprovedAt, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 100)
                }
                .padding(.horizontal, 16)
            }

            HStack {
                Button("Revoke", role: .destructive) {
                    if let id = selection { displayApprovals.revoke(name: id) }
                    selection = nil
                }
                .disabled(selection == nil)

                Spacer()

                Button("Revoke All") {
                    displayApprovals.revokeAll()
                    selection = nil
                }
                .disabled(displayApprovals.trusted.isEmpty)
            }
            .padding(16)
        }
    }
}

// MARK: - Shared subviews

private struct ManagedToggle: View {
    let title: String
    let binding: Binding<Bool>
    let managed: Bool?

    init(title: String, isOn binding: Binding<Bool>, managed: Bool?) {
        self.title = title
        self.binding = binding
        self.managed = managed
    }

    var body: some View {
        Toggle(isOn: managed != nil ? .constant(managed!) : binding) {
            HStack(spacing: 6) {
                Text(title)
                if managed != nil {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption2)
                }
            }
        }
        .disabled(managed != nil)
    }
}

private struct PolicyRow: View {
    let text: String
    let icon: String
    let tint: Color

    init(_ text: String, icon: String, tint: Color) {
        self.text = text
        self.icon = icon
        self.tint = tint
    }

    var body: some View {
        Label(text, systemImage: icon)
            .foregroundStyle(tint)
    }
}
