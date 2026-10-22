import Foundation
import ServiceManagement
import Testing
@testable import AgentMeter

@Suite(.serialized)
struct AgentMeterTests {
    @Test func usagePeriodMatchesKnownDurations() {
        #expect(AgentUsagePeriod.period(forDurationMinutes: 300) == .fiveHours)
        #expect(AgentUsagePeriod.period(forDurationMinutes: 10_080) == .week)
        #expect(AgentUsagePeriod.period(forDurationMinutes: 60) == nil)
    }

    @Test func usageRatioIsClamped() {
        let overLimit = AgentUsageWindow(
            durationMinutes: 300,
            usedPercentage: 125,
            resetsAt: nil
        )
        let underLimit = AgentUsageWindow(
            durationMinutes: 300,
            usedPercentage: -10,
            resetsAt: nil
        )

        #expect(overLimit.usedRatio == 1)
        #expect(underLimit.usedRatio == 0)
    }

    @Test func codexRateLimitResponseSupportsKnownKeyStyles() throws {
        let response: [String: Any] = [
            "primary": [
                "windowDurationMins": 300,
                "usedPercent": "42.6%",
                "resetsAt": 1_800_000_000
            ],
            "secondary": [
                "window_minutes": "10080",
                "used_percent": 101,
                "resets_at": "1800003600"
            ],
            "ignored": ["usedPercent": 12]
        ]

        let windows = RateLimitWindowExtractor.windows(from: response)
        let fiveHours = try #require(windows.first { $0.durationMinutes == 300 })
        let week = try #require(windows.first { $0.durationMinutes == 10_080 })

        #expect(fiveHours.usedPercentage == 43)
        #expect(fiveHours.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(week.usedPercentage == 100)
        #expect(week.resetsAt == Date(timeIntervalSince1970: 1_800_003_600))
        #expect(windows.count == 2)
    }

    @Test @MainActor func failedRefreshKeepsValidLastKnownUsage() async throws {
        let lastUpdated = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = Date().addingTimeInterval(3_600)
        let provider = SequencedUsageProvider(responses: [
            [.connectedCodex(usedPercentage: 37, resetsAt: reset, lastUpdated: lastUpdated)],
            [.unavailableCodex]
        ])
        let viewModel = DashboardViewModel(
            usageProvider: provider,
            credentialStore: TestCredentialStore(connectedServices: [.openAI]),
            defaults: makeDefaults()
        )

        await viewModel.loadUsage()
        await viewModel.loadUsage()

        let codex = try #require(viewModel.agents.first { $0.kind == .codex })
        #expect(codex.isConnected)
        #expect(codex.usageWindows.first?.usedPercentage == 37)
        #expect(codex.lastUpdated == lastUpdated)
        #expect(viewModel.errorMessage == "Could not refresh all usage. Showing last known data.")
    }

    @Test @MainActor func failedRefreshDropsExpiredLastKnownUsage() async throws {
        let provider = SequencedUsageProvider(responses: [
            [.connectedCodex(usedPercentage: 37, resetsAt: Date().addingTimeInterval(-1))],
            [.unavailableCodex]
        ])
        let viewModel = DashboardViewModel(
            usageProvider: provider,
            credentialStore: TestCredentialStore(connectedServices: [.openAI]),
            defaults: makeDefaults()
        )

        await viewModel.loadUsage()
        await viewModel.loadUsage()

        let codex = try #require(viewModel.agents.first { $0.kind == .codex })
        #expect(!codex.isConnected)
        #expect(codex.usageWindows.isEmpty)
        #expect(viewModel.errorMessage == nil)
    }

    @Test @MainActor func overlappingRefreshIsIgnored() async {
        let provider = DelayedUsageProvider(response: [.connectedCodex(usedPercentage: 12)])
        let viewModel = DashboardViewModel(
            usageProvider: provider,
            credentialStore: TestCredentialStore(connectedServices: [.openAI]),
            defaults: makeDefaults()
        )

        let firstRefresh = Task { await viewModel.loadUsage() }
        while !viewModel.isRefreshing {
            await Task.yield()
        }

        await viewModel.loadUsage()
        await firstRefresh.value

        #expect(provider.callCount == 1)
        #expect(!viewModel.isRefreshing)
    }

    @Test @MainActor func menuBarShowsOneBarPerServiceByDefault() async {
        let viewModel = makeClaudeViewModel(defaults: makeDefaults())

        await viewModel.loadUsage()

        #expect(viewModel.menuBarGroups.map(\.agent.kind) == [.claudeCode])
        #expect(viewModel.menuBarGroups.first?.entries.map(\.item.period) == [.fiveHours])
        #expect(viewModel.menuBarItemStyle(for: .init(kind: .codex, period: .week)).isEnabled)
    }

    @Test @MainActor func everyBarCanBeTurnedOnAndOffIndependently() async {
        let defaults = makeDefaults()
        let viewModel = makeClaudeViewModel(defaults: defaults)
        await viewModel.loadUsage()

        viewModel.toggleMenuBarItem(.init(kind: .claudeCode, period: .week))
        #expect(viewModel.menuBarGroups.first?.entries.map(\.item.period) == [.fiveHours, .week])

        viewModel.toggleMenuBarItem(.init(kind: .claudeCode, period: .fiveHours))
        #expect(viewModel.menuBarGroups.first?.entries.map(\.item.period) == [.week])

        let reloaded = makeClaudeViewModel(defaults: defaults)
        await reloaded.loadUsage()
        #expect(reloaded.menuBarGroups.first?.entries.map(\.item.period) == [.week])
    }

    @Test @MainActor func turningOffEveryBarOfAServiceHidesIt() async {
        let viewModel = makeClaudeViewModel(defaults: makeDefaults())
        await viewModel.loadUsage()

        viewModel.toggleMenuBarItem(.init(kind: .claudeCode, period: .fiveHours))

        #expect(viewModel.menuBarGroups.isEmpty)
    }

    @Test @MainActor func knownPeriodsAreOfferedBeforeDataArrives() {
        let viewModel = DashboardViewModel(
            usageProvider: SequencedUsageProvider(responses: []),
            credentialStore: TestCredentialStore(connectedServices: [.openAI, .claudeCode]),
            defaults: makeDefaults()
        )

        #expect(viewModel.menuBarItems.map(\.id) == ["codex.week", "claudeCode.fiveHours", "claudeCode.week"])
    }

    @Test @MainActor func servicesNotAddedAreLeftOutOfMenuBarChoices() {
        let claudeOnly = makeClaudeViewModel(defaults: makeDefaults())
        let none = DashboardViewModel(
            usageProvider: SequencedUsageProvider(responses: []),
            credentialStore: TestCredentialStore(connectedServices: []),
            defaults: makeDefaults()
        )

        #expect(claudeOnly.menuBarItems.map(\.id) == ["claudeCode.fiveHours", "claudeCode.week"])
        #expect(none.menuBarItems.isEmpty)
    }

    @Test @MainActor func legacyPeriodSettingIsCarriedOver() async {
        let defaults = makeDefaults()
        defaults.set("week", forKey: "agentmeter.menu-bar-usage-period.claudeCode")
        let viewModel = makeClaudeViewModel(defaults: defaults)

        await viewModel.loadUsage()

        #expect(viewModel.menuBarGroups.first?.entries.map(\.item.period) == [.week])
    }

    @Test @MainActor func eachBarKeepsItsOwnStyle() {
        let defaults = makeDefaults()
        let viewModel = makeClaudeViewModel(defaults: defaults)
        let week = MenuBarItemID(kind: .claudeCode, period: .week)
        let style = MenuBarItemStyle(isEnabled: true, showsLabel: false, showsBar: false, value: .remainingPercentage)

        viewModel.setMenuBarItemStyle(style, for: week)

        let reloaded = makeClaudeViewModel(defaults: defaults)
        #expect(reloaded.menuBarItemStyle(for: week) == style)
        #expect(reloaded.menuBarItemStyle(for: .init(kind: .claudeCode, period: .fiveHours)) == MenuBarItemStyle(isEnabled: true))
    }

    @Test func valueStyleFormatsUsage() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = AgentUsageWindow(durationMinutes: 300, usedPercentage: 42, resetsAt: now.addingTimeInterval(2 * 3_600 + 5 * 60))

        #expect(MenuBarValueStyle.hidden.text(for: usage, now: now) == nil)
        #expect(MenuBarValueStyle.usedPercentage.text(for: usage, now: now) == "42%")
        #expect(MenuBarValueStyle.usedNumber.text(for: usage, now: now) == "42")
        #expect(MenuBarValueStyle.remainingPercentage.text(for: usage, now: now) == "58%")
        #expect(MenuBarValueStyle.remainingNumber.text(for: usage, now: now) == "58")
        #expect(MenuBarValueStyle.resetCountdown.text(for: usage, now: now) == "2h 5m")
        #expect(MenuBarValueStyle.usedPercentage.text(for: nil, now: now) == "—")
    }

    @Test func firstRunGuideOpensSettingsOnceForANewUser() {
        let guide = FirstRunGuide(defaults: makeDefaults())

        #expect(guide.shouldOpenSettings(hasAccount: false))
        // Every later launch, even with no account, is left to the user.
        #expect(!guide.shouldOpenSettings(hasAccount: false))
    }

    @Test func firstRunGuideNeverInterruptsSomeoneWithAnAccount() {
        let defaults = makeDefaults()

        #expect(!FirstRunGuide(defaults: defaults).shouldOpenSettings(hasAccount: true))
        // Removing every account later must not bring the guide back.
        #expect(!FirstRunGuide(defaults: defaults).shouldOpenSettings(hasAccount: false))
    }

    @Test @MainActor func launchAtLoginTurnsOnOnceForAnInstalledApp() {
        let service = FakeLoginItemService()
        let defaults = makeDefaults()

        let first = LaunchAtLogin(service: service, defaults: defaults, bundlePath: "/Applications/AgentMeter.app")
        #expect(first.isEnabled)
        #expect(service.registerCount == 1)

        // The user turns it off; later launches must not turn it back on.
        first.setEnabled(false)
        #expect(!first.isEnabled)
        let second = LaunchAtLogin(service: service, defaults: defaults, bundlePath: "/Applications/AgentMeter.app")
        #expect(!second.isEnabled)
        #expect(service.registerCount == 1)
    }

    @Test @MainActor func launchAtLoginIsLeftAloneForDevelopmentBuilds() {
        let service = FakeLoginItemService()

        let launchAtLogin = LaunchAtLogin(
            service: service,
            defaults: makeDefaults(),
            bundlePath: "/Users/someone/Library/Developer/Xcode/DerivedData/AgentMeter/Build/Products/Debug/AgentMeter.app"
        )

        #expect(!launchAtLogin.isEnabled)
        #expect(service.registerCount == 0)
    }

    @Test @MainActor func launchAtLoginReportsApprovalAndFailures() {
        let service = FakeLoginItemService(registeredStatus: .requiresApproval)
        let launchAtLogin = LaunchAtLogin(service: service, defaults: makeDefaults(), bundlePath: "/tmp/AgentMeter.app")

        launchAtLogin.setEnabled(true)
        #expect(launchAtLogin.needsApproval)
        #expect(launchAtLogin.isEnabled)

        service.shouldFail = true
        launchAtLogin.setEnabled(false)
        #expect(launchAtLogin.errorMessage == "Could not turn off Launch at login.")
    }

    @Test func installSourceDetectsHomebrewCask() {
        let homebrew = InstallSource.detect(
            caskroomDirectories: ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"],
            fileExists: { $0 == "/usr/local/Caskroom/agent-meter" }
        )
        let direct = InstallSource.detect(
            caskroomDirectories: ["/opt/homebrew/Caskroom"],
            fileExists: { _ in false }
        )

        #expect(homebrew == .homebrew)
        #expect(direct == .direct)
    }

    @Test func resetCountdownIsCompact() {
        #expect(MenuBarValueStyle.compactDuration(30) == "1m")
        #expect(MenuBarValueStyle.compactDuration(45 * 60) == "45m")
        #expect(MenuBarValueStyle.compactDuration(3 * 3_600) == "3h")
        #expect(MenuBarValueStyle.compactDuration(3 * 86_400 + 4 * 3_600) == "3d 4h")
        #expect(MenuBarValueStyle.compactDuration(-10) == "0m")
    }

    @MainActor private func makeClaudeViewModel(defaults: UserDefaults) -> DashboardViewModel {
        DashboardViewModel(
            usageProvider: SequencedUsageProvider(responses: [[.connectedClaudeCode]]),
            credentialStore: TestCredentialStore(connectedServices: [.claudeCode]),
            defaults: defaults
        )
    }

    /// An isolated, emptied suite so tests never touch the app's real settings. The suite is serialized,
    /// so one shared name is enough.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "dev.scolor.AgentMeterTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private final class TestCredentialStore: AgentCredentialStoring {
    private var connectedServices: Set<AgentCredentialService>

    init(connectedServices: Set<AgentCredentialService>) {
        self.connectedServices = connectedServices
    }

    func saveCLILogin(for service: AgentCredentialService) throws {
        connectedServices.insert(service)
    }

    func deleteConnection(for service: AgentCredentialService) throws {
        connectedServices.remove(service)
    }

    func hasConnection(for service: AgentCredentialService) -> Bool {
        connectedServices.contains(service)
    }
}

private final class SequencedUsageProvider: AgentUsageProviding {
    private var responses: [[AgentUsageSnapshot]]

    init(responses: [[AgentUsageSnapshot]]) {
        self.responses = responses
    }

    func usageSnapshots() async throws -> [AgentUsageSnapshot] {
        responses.removeFirst()
    }
}

private final class DelayedUsageProvider: AgentUsageProviding {
    private let response: [AgentUsageSnapshot]
    private(set) var callCount = 0

    init(response: [AgentUsageSnapshot]) {
        self.response = response
    }

    func usageSnapshots() async throws -> [AgentUsageSnapshot] {
        callCount += 1
        try await Task.sleep(for: .milliseconds(100))
        return response
    }
}

private extension AgentUsageSnapshot {
    static func connectedCodex(
        usedPercentage: Int,
        resetsAt: Date? = nil,
        lastUpdated: Date = Date()
    ) -> AgentUsageSnapshot {
        AgentUsageSnapshot(
            kind: .codex,
            isConnected: true,
            lastUpdated: lastUpdated,
            usageWindows: [
                AgentUsageWindow(
                    durationMinutes: 300,
                    usedPercentage: usedPercentage,
                    resetsAt: resetsAt
                )
            ]
        )
    }

    static var connectedClaudeCode: AgentUsageSnapshot {
        AgentUsageSnapshot(
            kind: .claudeCode,
            isConnected: true,
            lastUpdated: Date(),
            usageWindows: [
                AgentUsageWindow(durationMinutes: 300, usedPercentage: 20, resetsAt: nil),
                AgentUsageWindow(durationMinutes: 10_080, usedPercentage: 60, resetsAt: nil)
            ]
        )
    }

    static var unavailableCodex: AgentUsageSnapshot {
        AgentUsageSnapshot(kind: .codex, isConnected: false, lastUpdated: nil)
    }
}

private final class FakeLoginItemService: LoginItemService {
    struct Failure: Error {}

    var status: SMAppService.Status = .notRegistered
    var shouldFail = false
    private(set) var registerCount = 0
    private let registeredStatus: SMAppService.Status

    init(registeredStatus: SMAppService.Status = .enabled) {
        self.registeredStatus = registeredStatus
    }

    func register() throws {
        if shouldFail { throw Failure() }
        registerCount += 1
        status = registeredStatus
    }

    func unregister() throws {
        if shouldFail { throw Failure() }
        status = .notRegistered
    }
}
