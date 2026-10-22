import SwiftUI

struct AgentMeterSettingsView: View {
    private var hasAccount: Bool {
        AgentKind.allCases.contains(where: viewModel.hasConfiguredConnection(for:))
    }

    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var updater: AppUpdater
    @ObservedObject var launchAtLogin: LaunchAtLogin
    @Environment(\.dismiss) private var dismiss
    var onDone: (() -> Void)?

    init(
        viewModel: DashboardViewModel,
        updater: AppUpdater,
        launchAtLogin: LaunchAtLogin,
        onDone: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.updater = updater
        self.launchAtLogin = launchAtLogin
        self.onDone = onDone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Settings")
                    .font(.title3.weight(.semibold))

                Spacer()

                Button("Done") {
                    if let onDone {
                        onDone()
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }

            MenuBarSettingsSection(viewModel: viewModel)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Accounts")
                    .font(.headline)

                Text(hasAccount
                    ? "Add or manage the agents whose usage appears in Agent Meter."
                    : "Welcome to Agent Meter. Add Codex or Claude Code below to see your usage in the menu bar. Each one uses the login you already have.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Every service is listed here, whether or not it has been added or has reported usage.
                ForEach(AgentKind.allCases) { kind in
                    let agent = viewModel.agents.first { $0.kind == kind }
                        ?? AgentUsageSnapshot(kind: kind, isConnected: false, lastUpdated: nil)
                    SettingsAccountRow(
                        agent: agent,
                        isConfigured: viewModel.hasConfiguredConnection(for: agent.kind)
                    ) {
                        viewModel.editConnection(for: agent)
                    }
                }
            }

            Divider()

            GeneralSettingsSection(launchAtLogin: launchAtLogin)

            Divider()

            UpdateSettingsSection(updater: updater)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(width: 480)
        .sheet(item: $viewModel.connectionEditor) { editor in
            AgentConnectionEditorView(
                editor: editor,
                onSave: {
                    viewModel.saveConnection(for: editor.kind)
                },
                onDelete: {
                    viewModel.deleteConnection(for: editor.kind)
                },
                onCancel: {
                    viewModel.connectionEditor = nil
                }
            )
        }
    }
}

private struct GeneralSettingsSection: View {
    @ObservedObject var launchAtLogin: LaunchAtLogin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("General")
                .font(.headline)

            Toggle("Launch Agent Meter at login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)

            if launchAtLogin.needsApproval {
                HStack(spacing: 4) {
                    Text("Allow Agent Meter under Login Items in System Settings to finish turning this on.")
                        .foregroundStyle(.secondary)

                    Button("Open Settings") {
                        launchAtLogin.openSystemSettings()
                    }
                    .buttonStyle(.link)
                }
                .font(.caption)
            }

            if let errorMessage = launchAtLogin.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear {
            launchAtLogin.refresh()
        }
    }
}

private struct UpdateSettingsSection: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Updates")
                    .font(.headline)

                Spacer()

                Text("Version \(updater.currentVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if updater.isAvailable {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.setAutomaticallyChecksForUpdates($0) }
                ))

                Toggle("Download and install updates automatically", isOn: Binding(
                    get: { updater.automaticallyDownloadsUpdates },
                    set: { updater.setAutomaticallyDownloadsUpdates($0) }
                ))
                .disabled(!updater.automaticallyChecksForUpdates)

                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            } else {
                Text("In-app updates are not available in this build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            manualUpdateNote
        }
        .toggleStyle(.checkbox)
        .font(.caption)
    }

    @ViewBuilder
    private var manualUpdateNote: some View {
        switch updater.installSource {
        case .homebrew:
            VStack(alignment: .leading, spacing: 4) {
                Text("Installed with Homebrew. To update manually, run:")
                    .foregroundStyle(.secondary)

                Text(InstallSource.homebrewUpgradeCommand)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        case .direct:
            HStack(spacing: 4) {
                Text("To update manually, download the latest version from")
                    .foregroundStyle(.secondary)

                Link("GitHub Releases", destination: InstallSource.releasesURL)
            }
        }
    }
}

private struct MenuBarSettingsSection: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Menu Bar")
                .font(.headline)

            Text("Choose which bars appear in the menu bar and what each one shows. Usage is reported as a percentage; token counts are not available.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.menuBarItems.isEmpty {
                Text("Add an account below to choose what appears in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                MenuBarPreview(viewModel: viewModel)

                VStack(spacing: 0) {
                    ForEach(Array(viewModel.menuBarItems.enumerated()), id: \.element) { index, item in
                        if index > 0 {
                            Divider()
                        }
                        MenuBarItemSettingsRow(item: item, viewModel: viewModel)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

private struct MenuBarPreview: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        let snapshots = previewSnapshots
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Spacer()
                MenuBarStatusLabel(groups: viewModel.menuBarGroups(for: snapshots.agents))
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.bar, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1))
            )
            .accessibilityLabel("Menu bar preview")

            if snapshots.usesSampleData {
                Text("Preview uses sample values for services without usage data.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Live usage where it exists, otherwise sample values so every option can be previewed.
    private var previewSnapshots: (agents: [AgentUsageSnapshot], usesSampleData: Bool) {
        var usesSampleData = false
        let agents = AgentKind.allCases.filter(viewModel.hasConfiguredConnection(for:)).map { kind -> AgentUsageSnapshot in
            if let live = viewModel.agents.first(where: { $0.kind == kind && !$0.usageWindows.isEmpty }) {
                return live
            }
            usesSampleData = true
            return AgentUsageSnapshot.sample(for: kind)
        }
        return (agents, usesSampleData)
    }
}

private struct MenuBarItemSettingsRow: View {
    let item: MenuBarItemID
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        let style = viewModel.menuBarItemStyle(for: item)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(item.kind.assetName)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)

                Text(item.displayName)
                    .font(.caption.weight(.semibold))

                Spacer()

                Toggle("Show \(item.displayName)", isOn: binding(\.isEnabled))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }

            if style.isEnabled {
                HStack(spacing: 12) {
                    Toggle("Label", isOn: binding(\.showsLabel))
                    Toggle("Bar", isOn: binding(\.showsBar))

                    Picker("Value", selection: binding(\.value)) {
                        ForEach(MenuBarValueStyle.allCases) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .fixedSize()
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.caption)
                .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<MenuBarItemStyle, Value>) -> Binding<Value> {
        Binding(
            get: { viewModel.menuBarItemStyle(for: item)[keyPath: keyPath] },
            set: { newValue in
                var style = viewModel.menuBarItemStyle(for: item)
                style[keyPath: keyPath] = newValue
                viewModel.setMenuBarItemStyle(style, for: item)
            }
        )
    }
}

private extension AgentUsageSnapshot {
    static func sample(for kind: AgentKind) -> AgentUsageSnapshot {
        let now = Date()
        let windows: [AgentUsageWindow]
        switch kind {
        case .codex:
            windows = [
                AgentUsageWindow(durationMinutes: 10_080, usedPercentage: 37, resetsAt: now.addingTimeInterval(3 * 86_400 + 4 * 3_600))
            ]
        case .claudeCode:
            windows = [
                AgentUsageWindow(durationMinutes: 300, usedPercentage: 42, resetsAt: now.addingTimeInterval(2 * 3_600 + 5 * 60)),
                AgentUsageWindow(durationMinutes: 10_080, usedPercentage: 60, resetsAt: now.addingTimeInterval(4 * 86_400))
            ]
        }
        return AgentUsageSnapshot(kind: kind, isConnected: true, lastUpdated: now, usageWindows: windows)
    }
}

private struct SettingsAccountRow: View {
    let agent: AgentUsageSnapshot
    let isConfigured: Bool
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            agent.icon
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.caption.weight(.semibold))

                Text(isConfigured ? "Added to Agent Meter" : "Not added")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(isConfigured ? "Manage" : "Add") {
                onEdit()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AgentConnectionEditorView: View {
    let editor: AgentConnectionEditor
    let onSave: () -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var cliCheck: CLIConnectionCheck?
    @State private var isCheckingCLI = false
    @State private var isLoggingIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(editor.kind.assetName)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect \(editor.kind.displayName)")
                        .font(.headline)

                    Text(editor.kind.cliDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Label(editor.kind.cliDisplayName, systemImage: "terminal")
                    .font(.caption.weight(.semibold))

                Text(editor.kind.cliRequirementText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: cliCheck?.systemImage ?? "clock")
                        .foregroundStyle(cliCheck?.tint ?? .secondary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(isCheckingCLI ? "Checking CLI..." : (cliCheck?.title ?? "Not checked"))
                            .font(.caption.weight(.semibold))

                        Text(cliCheck?.message ?? "Check the current login status.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 6) {
                        if cliCheck?.canConnect == false, cliCheck?.isInstalled == true {
                            Button(isLoggingIn ? "Logging in..." : "Log in") {
                                loginCLI()
                            }
                            .controlSize(.small)
                            .disabled(isLoggingIn || isCheckingCLI)
                        }

                        Button("Recheck") {
                            checkCLI()
                        }
                        .controlSize(.small)
                        .disabled(isLoggingIn || isCheckingCLI)
                    }
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(editor.kind.privacyNoteText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Remove") {
                    onDelete()
                }
                .foregroundStyle(.red)

                Spacer()

                Button("Cancel") {
                    onCancel()
                }

                Button("Save") {
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isLoggingIn || cliCheck?.canConnect != true)
            }
        }
        .padding(18)
        .frame(width: 360)
        .task {
            checkCLI()
        }
    }

    private func checkCLI() {
        isCheckingCLI = true
        Task {
            let result = await LocalCLIConnectionVerifier.check(kind: editor.kind)
            await MainActor.run {
                cliCheck = result
                isCheckingCLI = false
            }
        }
    }

    private func loginCLI() {
        isLoggingIn = true
        Task {
            let result = await LocalCLIConnectionVerifier.login(kind: editor.kind)
            await MainActor.run {
                cliCheck = result
                isLoggingIn = false
            }
        }
    }
}
