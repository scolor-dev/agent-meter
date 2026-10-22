import AppKit
import Combine
import SwiftUI

@main
struct AgentMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var statusHostingView: NSHostingView<AnyView>?
    private let statusMenu = NSMenu()
    private let viewModel = DashboardViewModel.shared
    private let updater = AppUpdater()
    private var settingsWindow: NSWindow?
    private var viewModelObserver: AnyCancellable?
    private var updaterObserver: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var isMenuOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureMenu()
        observeViewModel()
        startRefreshingUsage()
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTask?.cancel()
    }

    private func configureStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        guard let button = statusItem.button else {
            return
        }

        button.image = nil
        button.title = ""

        let hostingView = NSHostingView(rootView: statusView())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.setAccessibilityElement(false)
        button.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: button.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])

        statusHostingView = hostingView
        updateStatusItemLength()
    }

    private func statusView() -> AnyView {
        AnyView(
            MenuBarStatusLabel(groups: viewModel.menuBarGroups)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .fixedSize()
        )
    }

    /// The width depends on how many bars and which labels are shown, so size the item to its content.
    private func updateStatusItemLength() {
        let measuringView = NSHostingView(rootView: statusView())
        statusItem?.length = ceil(measuringView.fittingSize.width)
    }

    private func configureMenu() {
        statusMenu.delegate = self
        statusItem?.menu = statusMenu
        rebuildMenu()
    }

    private func observeViewModel() {
        viewModelObserver = viewModel.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }

                self.updateStatusView()
                if !self.isMenuOpen {
                    self.rebuildMenu()
                }
            }
        }
        updaterObserver = updater.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.isMenuOpen else { return }
                self.rebuildMenu()
            }
        }
    }

    private func startRefreshingUsage() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.viewModel.loadUsage()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func updateStatusView() {
        statusHostingView?.rootView = statusView()
        updateStatusItemLength()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        rebuildMenu()
    }

    private func rebuildMenu() {
        statusMenu.removeAllItems()
        statusMenu.addItem(.sectionHeader(title: "Agent Meter"))

        let configuredAgents = viewModel.agents.filter {
            viewModel.hasConfiguredConnection(for: $0.kind)
        }

        if configuredAgents.isEmpty {
            addInformationalItem("No accounts added", systemImage: "link.badge.plus")
        } else {
            for (index, agent) in configuredAgents.enumerated() {
                if index > 0 {
                    statusMenu.addItem(.separator())
                }
                addAgentItems(agent)
            }
        }

        if let errorMessage = viewModel.errorMessage {
            addInformationalItem(errorMessage, systemImage: "exclamationmark.triangle")
        }

        if let lastUpdatedAt = viewModel.lastUpdatedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            addInformationalItem(
                "Updated \(formatter.localizedString(for: lastUpdatedAt, relativeTo: Date()))",
                systemImage: "clock"
            )
        }

        statusMenu.addItem(.separator())
        statusMenu.addItem(actionItem(
            viewModel.isRefreshing ? "Refreshing…" : "Refresh",
            action: #selector(refreshUsage),
            keyEquivalent: "r",
            systemImage: "arrow.clockwise",
            isEnabled: !viewModel.isRefreshing
        ))
        statusMenu.addItem(menuBarDisplayMenuItem())
        statusMenu.addItem(actionItem(
            "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ",",
            systemImage: "person.crop.circle"
        ))
        statusMenu.addItem(actionItem(
            "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: "",
            systemImage: "arrow.down.circle",
            isEnabled: updater.canCheckForUpdates
        ))
        statusMenu.addItem(.separator())
        statusMenu.addItem(actionItem(
            "Quit Agent Meter",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        ))
    }

    private func addAgentItems(_ agent: AgentUsageSnapshot) {
        let headerItem = NSMenuItem(title: agent.name, action: nil, keyEquivalent: "")
        if let image = NSImage(named: agent.kind.assetName) {
            image.size = NSSize(width: 16, height: 16)
            headerItem.image = image
        }
        headerItem.isEnabled = false
        statusMenu.addItem(headerItem)

        guard agent.isConnected else {
            addInformationalItem("Unavailable", systemImage: "exclamationmark.circle")
            return
        }

        guard !agent.usageWindows.isEmpty else {
            addInformationalItem("No usage data", systemImage: "chart.bar")
            return
        }

        for usage in agent.usageWindows.sorted(using: KeyPathComparator(\.durationMinutes)) {
            let periodName = AgentUsagePeriod.period(forDurationMinutes: usage.durationMinutes)?.displayName
                ?? usage.displayName
            let usageView = MenuUsageBarView(
                periodName: periodName,
                usage: usage,
                tint: agent.tint
            )
            let hostingView = NSHostingView(rootView: usageView)
            hostingView.frame = NSRect(x: 0, y: 0, width: 290, height: usage.resetsAt == nil ? 42 : 56)

            let item = NSMenuItem()
            item.view = hostingView
            item.setAccessibilityLabel(
                "\(agent.name), \(periodName), \(usage.usedPercentage) percent used"
            )
            statusMenu.addItem(item)
        }
    }

    private func addInformationalItem(_ title: String, systemImage: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        item.isEnabled = false
        statusMenu.addItem(item)
    }

    private func actionItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String,
        systemImage: String? = nil,
        isEnabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.isEnabled = isEnabled
        if let systemImage {
            item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        }
        return item
    }

    private func menuBarDisplayMenuItem() -> NSMenuItem {
        let displayItem = NSMenuItem(title: "Menu Bar Display", action: nil, keyEquivalent: "")
        displayItem.image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: nil)

        let displayMenu = NSMenu(title: "Menu Bar Display")

        if viewModel.menuBarItems.isEmpty {
            let emptyItem = NSMenuItem(title: "Add an account to choose bars", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            displayMenu.addItem(emptyItem)
        }

        for item in viewModel.menuBarItems {
            let toggleItem = NSMenuItem(
                title: item.displayName,
                action: #selector(toggleMenuBarItem(_:)),
                keyEquivalent: ""
            )
            toggleItem.target = self
            toggleItem.state = viewModel.menuBarItemStyle(for: item).isEnabled ? .on : .off
            toggleItem.representedObject = MenuBarItemSelection(item: item)
            if let image = NSImage(named: item.kind.assetName) {
                image.size = NSSize(width: 16, height: 16)
                toggleItem.image = image
            }
            displayMenu.addItem(toggleItem)
        }

        displayMenu.addItem(.separator())
        displayMenu.addItem(actionItem(
            "Customize…",
            action: #selector(showSettings),
            keyEquivalent: ""
        ))

        displayItem.submenu = displayMenu
        return displayItem
    }

    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates()
    }

    @objc private func refreshUsage() {
        viewModel.refresh()
    }

    @objc private func toggleMenuBarItem(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? MenuBarItemSelection else {
            return
        }

        viewModel.toggleMenuBarItem(selection.item)
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let contentView = AgentMeterSettingsView(viewModel: viewModel, updater: updater) { [weak self] in
                self?.settingsWindow?.close()
            }
            let hostingController = NSHostingController(rootView: contentView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Agent Meter Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }
}

private final class MenuBarItemSelection: NSObject {
    let item: MenuBarItemID

    init(item: MenuBarItemID) {
        self.item = item
    }
}

private struct MenuUsageBarView: View {
    let periodName: String
    let usage: AgentUsageWindow
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(periodName)
                    .font(.caption.weight(.medium))

                Spacer()

                Text("\(usage.usedPercentage)% used")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }

            ProgressView(value: usage.usedRatio)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(tint)

            if let resetsAt = usage.resetsAt {
                Text("Resets \(resetsAt, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(width: 290)
    }
}
