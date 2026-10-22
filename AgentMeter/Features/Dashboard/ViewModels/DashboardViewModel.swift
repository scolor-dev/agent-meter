import SwiftUI

@MainActor
final class DashboardViewModel: ObservableObject {
    static let shared = DashboardViewModel()
    private static let menuBarItemsDefaultsKey = "agentmeter.menu-bar.items"
    private static let legacyMenuBarPeriodDefaultsKeyPrefix = "agentmeter.menu-bar-usage-period."

    @Published private(set) var agents: [AgentUsageSnapshot] = []
    @Published private(set) var isRefreshing = false
    @Published var connectionEditor: AgentConnectionEditor?
    @Published var errorMessage: String?
    @Published private var menuBarItemStyles: [String: MenuBarItemStyle]

    private let usageProvider: AgentUsageProviding
    private let credentialStore: AgentCredentialStoring
    private let defaults: UserDefaults

    init(
        usageProvider: AgentUsageProviding = LocalCLIUsageProvider(),
        credentialStore: AgentCredentialStoring = AgentCredentialStore.shared,
        defaults: UserDefaults = .standard
    ) {
        self.menuBarItemStyles = Self.loadMenuBarItemStyles(from: defaults)
        self.usageProvider = usageProvider
        self.credentialStore = credentialStore
        self.defaults = defaults
        loadCachedSnapshots()
    }

    var lastUpdatedAt: Date? {
        agents.compactMap(\.lastUpdated).max()
    }

    /// Every bar that can be placed in the menu bar for the services added in Settings: the periods
    /// each one is known to report, plus any other period it currently returns.
    var menuBarItems: [MenuBarItemID] {
        AgentKind.allCases.filter(hasConfiguredConnection(for:)).flatMap { kind in
            let available = availablePeriods(for: kind)
            return AgentUsagePeriod.allCases
                .filter { kind.knownPeriods.contains($0) || available.contains($0) }
                .map { MenuBarItemID(kind: kind, period: $0) }
        }
    }

    var menuBarGroups: [MenuBarGroup] {
        menuBarGroups(for: agents.filter { hasConfiguredConnection(for: $0.kind) && $0.isConnected })
    }

    /// Groups for the given snapshots; the settings preview passes sample data through here too.
    func menuBarGroups(for snapshots: [AgentUsageSnapshot]) -> [MenuBarGroup] {
        snapshots.compactMap { agent in
            let entries = menuBarItems
                .filter { $0.kind == agent.kind }
                .compactMap { item -> MenuBarGroup.Entry? in
                    let style = menuBarItemStyle(for: item)
                    guard style.isEnabled else {
                        return nil
                    }
                    return MenuBarGroup.Entry(item: item, style: style, usage: agent.usage(for: item.period))
                }

            return entries.isEmpty ? nil : MenuBarGroup(agent: agent, entries: entries)
        }
    }

    func menuBarItemStyle(for item: MenuBarItemID) -> MenuBarItemStyle {
        menuBarItemStyles[item.id] ?? .defaultStyle(for: item)
    }

    func setMenuBarItemStyle(_ style: MenuBarItemStyle, for item: MenuBarItemID) {
        menuBarItemStyles[item.id] = style
        if let data = try? JSONEncoder().encode(menuBarItemStyles) {
            defaults.set(data, forKey: Self.menuBarItemsDefaultsKey)
        }
    }

    func toggleMenuBarItem(_ item: MenuBarItemID) {
        var style = menuBarItemStyle(for: item)
        style.isEnabled.toggle()
        setMenuBarItemStyle(style, for: item)
    }

    private func availablePeriods(for kind: AgentKind) -> [AgentUsagePeriod] {
        guard let agent = agents.first(where: { $0.kind == kind }) else {
            return []
        }

        return AgentUsagePeriod.allCases.filter { agent.usage(for: $0) != nil }
    }

    func hasConfiguredConnection(for kind: AgentKind) -> Bool {
        credentialStore.hasConnection(for: kind.credentialService)
    }

    func refresh() {
        Task {
            await loadUsage()
        }
    }

    func loadUsage() async {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        defer {
            isRefreshing = false
        }

        do {
            let refreshedAgents = try await usageProvider.usageSnapshots()
            let mergeResult = preservingLastKnownUsage(in: refreshedAgents)
            agents = mergeResult.agents
            errorMessage = mergeResult.usedLastKnownUsage
                ? "Could not refresh all usage. Showing last known data."
                : nil
        } catch {
            errorMessage = "Could not refresh usage."
        }
    }

    func editConnection(for agent: AgentUsageSnapshot) {
        connectionEditor = AgentConnectionEditor(kind: agent.kind)
    }

    func saveConnection(for kind: AgentKind) {
        Task {
            await saveCLIConnection(for: kind)
        }
    }

    func deleteConnection(for kind: AgentKind) {
        do {
            try credentialStore.deleteConnection(for: kind.credentialService)
            connectionEditor = nil
            refresh()
        } catch {
            errorMessage = "Could not remove the connection cleanly."
        }
    }

    private func loadCachedSnapshots() {
        agents = AgentKind.allCases.map { kind in
            AgentUsageSnapshot(
                kind: kind,
                isConnected: credentialStore.hasConnection(for: kind.credentialService),
                lastUpdated: nil
            )
        }
    }

    private func preservingLastKnownUsage(
        in refreshedAgents: [AgentUsageSnapshot],
        now: Date = Date()
    ) -> (agents: [AgentUsageSnapshot], usedLastKnownUsage: Bool) {
        var usedLastKnownUsage = false

        let mergedAgents = refreshedAgents.map { refreshedAgent in
            guard refreshedAgent.usageWindows.isEmpty,
                  hasConfiguredConnection(for: refreshedAgent.kind),
                  let previousAgent = agents.first(where: { $0.kind == refreshedAgent.kind }) else {
                return refreshedAgent
            }

            let validPreviousWindows = previousAgent.usageWindows.filter { usage in
                usage.resetsAt.map { $0 > now } ?? true
            }
            guard !validPreviousWindows.isEmpty else {
                return refreshedAgent
            }

            usedLastKnownUsage = true
            return AgentUsageSnapshot(
                kind: refreshedAgent.kind,
                isConnected: true,
                lastUpdated: previousAgent.lastUpdated,
                usageWindows: validPreviousWindows
            )
        }

        return (mergedAgents, usedLastKnownUsage)
    }

    private static func loadMenuBarItemStyles(from defaults: UserDefaults) -> [String: MenuBarItemStyle] {
        if let data = defaults.data(forKey: menuBarItemsDefaultsKey),
           let styles = try? JSONDecoder().decode([String: MenuBarItemStyle].self, from: data) {
            return styles
        }

        // Earlier versions stored one chosen period per service; carry that choice over.
        var styles: [String: MenuBarItemStyle] = [:]
        for kind in AgentKind.allCases {
            guard let legacyPeriod = defaults
                .string(forKey: "\(legacyMenuBarPeriodDefaultsKeyPrefix)\(kind.rawValue)")
                .flatMap(AgentUsagePeriod.init(rawValue:)) else {
                continue
            }

            for period in AgentUsagePeriod.allCases {
                let item = MenuBarItemID(kind: kind, period: period)
                styles[item.id] = MenuBarItemStyle(isEnabled: period == legacyPeriod)
            }
        }
        return styles
    }

    private func saveCLIConnection(for kind: AgentKind) async {
        let check = await LocalCLIConnectionVerifier.check(kind: kind)

        guard check.canConnect else {
            errorMessage = check.message
            return
        }

        do {
            try credentialStore.saveCLILogin(for: kind.credentialService)
            connectionEditor = nil
            refresh()
        } catch {
            errorMessage = "Could not save CLI connection."
        }
    }
}

struct LocalCLIUsageProvider: AgentUsageProviding {
    private let credentialStore: AgentCredentialStoring

    init(credentialStore: AgentCredentialStoring = AgentCredentialStore.shared) {
        self.credentialStore = credentialStore
    }

    func usageSnapshots() async throws -> [AgentUsageSnapshot] {
        var snapshots: [AgentUsageSnapshot] = []

        for kind in AgentKind.allCases {
            snapshots.append(await snapshot(for: kind))
        }

        return snapshots
    }

    private func snapshot(for kind: AgentKind) async -> AgentUsageSnapshot {
        guard credentialStore.hasConnection(for: kind.credentialService) else {
            return unavailableSnapshot(for: kind)
        }

        switch kind {
        case .codex:
            return await codexSnapshot()
        case .claudeCode:
            return await claudeCodeSnapshot()
        }
    }

    private func codexSnapshot() async -> AgentUsageSnapshot {
        guard let executableURL = await CLILocator.executableURL(named: "codex") else {
            return unavailableSnapshot(for: .codex)
        }

        let status = await CommandRunner.run(executableURL: executableURL, arguments: ["login", "status"], timeout: 4)
        guard status.exitCode == 0 else {
            return unavailableSnapshot(for: .codex)
        }

        let usage = await CodexRateLimitClient.fetch(executableURL: executableURL)

        if let usage {
            return AgentUsageSnapshot(
                kind: .codex,
                isConnected: true,
                lastUpdated: Date(),
                usageWindows: usage.windows
            )
        }

        return AgentUsageSnapshot(
            kind: .codex,
            isConnected: true,
            lastUpdated: nil
        )
    }

    private func claudeCodeSnapshot() async -> AgentUsageSnapshot {
        guard let executableURL = await CLILocator.executableURL(named: "claude") else {
            return unavailableSnapshot(for: .claudeCode)
        }

        let status = await CommandRunner.run(executableURL: executableURL, arguments: ["auth", "status"], timeout: 4)
        let output = "\(status.standardOutput)\n\(status.standardError)".lowercased()

        guard status.exitCode == 0, !output.contains("not logged"), !output.contains("not authenticated") else {
            return unavailableSnapshot(for: .claudeCode)
        }

        if let usage = await ClaudeCodeUsageAPIClient.fetch(executableURL: executableURL), !usage.windows.isEmpty {
            return AgentUsageSnapshot(
                kind: .claudeCode,
                isConnected: true,
                lastUpdated: usage.lastUpdated,
                usageWindows: usage.windows
            )
        }

        return AgentUsageSnapshot(
            kind: .claudeCode,
            isConnected: true,
            lastUpdated: nil
        )
    }

    private func unavailableSnapshot(for kind: AgentKind) -> AgentUsageSnapshot {
        AgentUsageSnapshot(
            kind: kind,
            isConnected: false,
            lastUpdated: nil
        )
    }
}

private struct ClaudeCodeUsage {
    let windows: [AgentUsageWindow]
    let lastUpdated: Date
}

/// Reads the OAuth access token that Claude Code stores in the macOS Keychain (shared by the
/// terminal CLI and every IDE extension using the same login) and calls Anthropic's usage
/// endpoint. Agent Meter never refreshes the token itself: when it has expired, it runs
/// `claude auth status` so Claude Code can renew its own credentials, then reads them again.
private enum ClaudeCodeUsageAPIClient {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"

    static func fetch(executableURL: URL) async -> ClaudeCodeUsage? {
        var stored = await readAccessToken()
        if stored.map({ $0.expiresAt <= Date().addingTimeInterval(30) }) ?? true {
            _ = await CommandRunner.run(executableURL: executableURL, arguments: ["auth", "status"], timeout: 15)
            stored = await readAccessToken()
        }

        guard let token = stored, token.expiresAt > Date() else {
            return nil
        }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let windows = windows(from: payload)
        guard !windows.isEmpty else {
            return nil
        }

        return ClaudeCodeUsage(windows: windows, lastUpdated: Date())
    }

    private static func windows(from payload: [String: Any]) -> [AgentUsageWindow] {
        let definitions = [
            (key: "five_hour", durationMinutes: 300),
            (key: "seven_day", durationMinutes: 10_080)
        ]
        let now = Date()

        return definitions.compactMap { definition -> AgentUsageWindow? in
            guard let value = payload[definition.key] as? [String: Any],
                  let utilization = number(from: value["utilization"]) else {
                return nil
            }

            let resetsAt = (value["resets_at"] as? String).flatMap(date(fromISO8601:))
            if let resetsAt, resetsAt <= now {
                return nil
            }

            return AgentUsageWindow(
                durationMinutes: definition.durationMinutes,
                usedPercentage: min(max(Int(utilization.rounded()), 0), 100),
                resetsAt: resetsAt
            )
        }
    }

    private struct StoredToken {
        let accessToken: String
        let expiresAt: Date
    }

    /// Claude Code writes this item with `/usr/bin/security`, which resets its access list on every
    /// token refresh. Reading through the same tool keeps it a trusted reader, so macOS does not ask
    /// for permission each time; reading it directly through the Keychain API does.
    private static func readAccessToken() async -> StoredToken? {
        let result = await CommandRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-generic-password", "-s", keychainService, "-w"],
            timeout: 5
        )

        guard result.exitCode == 0,
              let data = result.standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = payload["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              let expiresAtMillis = number(from: oauth["expiresAt"]) else {
            return nil
        }

        return StoredToken(accessToken: accessToken, expiresAt: Date(timeIntervalSince1970: expiresAtMillis / 1000))
    }

    private static func date(fromISO8601 string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) {
            return date
        }
        return ISO8601DateFormatter().date(from: string)
    }

    private static func number(from value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }

        if let string = value as? String {
            return Double(string)
        }

        return nil
    }
}

private struct CodexUsage {
    let windows: [AgentUsageWindow]
}

private enum CodexRateLimitClient {
    static func fetch(executableURL: URL) async -> CodexUsage? {
        await Task.detached {
            fetchBlocking(executableURL: executableURL)
        }.value
    }

    private static func fetchBlocking(executableURL: URL) -> CodexUsage? {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let responseSemaphore = DispatchSemaphore(value: 0)
        let stateQueue = DispatchQueue(label: "com.agentmeter.codex-rate-limits")

        var buffer = Data()
        var usage: CodexUsage?
        var didRequestRateLimits = false

        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.environment = CommandRunner.environment(for: executableURL)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            stateQueue.sync {
                buffer.append(data)

                while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.prefix(upTo: newlineIndex)
                    buffer.removeSubrange(...newlineIndex)

                    guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let responseID = object["id"] as? NSNumber else {
                        continue
                    }

                    if responseID.intValue == 0, !didRequestRateLimits {
                        didRequestRateLimits = true
                        write(
                            [
                                ["method": "initialized", "params": [:]],
                                ["method": "account/rateLimits/read", "id": 2, "params": NSNull()]
                            ],
                            to: inputPipe.fileHandleForWriting
                        )
                    } else if responseID.intValue == 2 {
                        usage = usageFromRateLimitResponse(object)
                        responseSemaphore.signal()
                    }
                }
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        write(
            [[
                "method": "initialize",
                "id": 0,
                "params": [
                    "clientInfo": [
                        "name": "agent_meter",
                        "title": "Agent Meter",
                        "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                    ],
                    "capabilities": ["experimentalApi": true]
                ]
            ]],
            to: inputPipe.fileHandleForWriting
        )

        _ = responseSemaphore.wait(timeout: .now() + 12)
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()

        if process.isRunning {
            process.terminate()
        }

        return stateQueue.sync { usage }
    }

    private static func write(_ messages: [[String: Any]], to handle: FileHandle) {
        for message in messages {
            guard let data = try? JSONSerialization.data(withJSONObject: message) else {
                continue
            }
            // `write(_:)` raises an Objective-C exception on a closed pipe; the throwing variant does not.
            try? handle.write(contentsOf: data + Data([0x0A]))
        }
    }

    private static func usageFromRateLimitResponse(_ response: [String: Any]) -> CodexUsage? {
        guard let result = response["result"] as? [String: Any] else {
            return nil
        }

        let rateLimitsByID = result["rateLimitsByLimitId"] as? [String: Any]
        let codexLimits = rateLimitsByID?["codex"] ?? result["rateLimits"]
        let windows = RateLimitWindowExtractor.windows(from: codexLimits as Any)

        guard !windows.isEmpty else {
            return nil
        }

        return CodexUsage(windows: windows)
    }
}

enum RateLimitWindowExtractor {
    static func windows(from object: Any) -> [AgentUsageWindow] {
        extract(from: object)
    }

    private static func extract(from object: Any) -> [AgentUsageWindow] {
        if let dictionary = object as? [String: Any] {
            var windows = dictionary.values.flatMap(extract)

            let durationMinutes = integerValue(dictionary["windowDurationMins"])
                ?? integerValue(dictionary["window_minutes"])
            let usedPercent = percentageValue(dictionary["usedPercent"])
                ?? percentageValue(dictionary["used_percent"])

            if let durationMinutes, let usedPercent {
                let resetsAtValue = integerValue(dictionary["resetsAt"])
                    ?? integerValue(dictionary["resets_at"])
                let resetsAt = resetsAtValue.map {
                    Date(timeIntervalSince1970: TimeInterval($0))
                }
                windows.append(
                    AgentUsageWindow(
                        durationMinutes: durationMinutes,
                        usedPercentage: usedPercent,
                        resetsAt: resetsAt
                    )
                )
            }

            return windows
        }

        if let array = object as? [Any] {
            return array.flatMap(extract)
        }

        return []
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private static func percentageValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return min(max(Int(number.doubleValue.rounded()), 0), 100)
        } else if let string = value as? String {
            return Double(string.replacingOccurrences(of: "%", with: "")).map {
                min(max(Int($0.rounded()), 0), 100)
            }
        }
        return nil
    }
}

private struct CommandResult {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

enum LocalCLIConnectionVerifier {
    static func check(kind: AgentKind) async -> CLIConnectionCheck {
        switch kind {
        case .codex:
            return await codexCheck()
        case .claudeCode:
            return await claudeCodeCheck()
        }
    }

    static func login(kind: AgentKind) async -> CLIConnectionCheck {
        let executableName = kind == .codex ? "codex" : "claude"
        guard let executableURL = await CLILocator.executableURL(named: executableName) else {
            return CLIConnectionCheck(
                canConnect: false,
                isInstalled: false,
                title: "\(kind.cliDisplayName) not found",
                message: "Install \(kind.cliDisplayName), then recheck.",
                systemImage: "xmark.circle.fill",
                tint: .red
            )
        }

                let result = await CommandRunner.run(
            executableURL: executableURL,
            arguments: kind == .codex ? ["login"] : ["auth", "login"],
            timeout: 300
        )

        guard result.exitCode == 0 else {
            let detail = firstUsefulLine(in: result.standardError, fallback: result.standardOutput)
            return CLIConnectionCheck(
                canConnect: false,
                isInstalled: true,
                title: "Login did not complete",
                message: detail ?? "The CLI login command exited before authentication completed.",
                systemImage: "exclamationmark.circle.fill",
                tint: .orange
            )
        }

        return await check(kind: kind)
    }

    private static func codexCheck() async -> CLIConnectionCheck {
        guard let executableURL = await CLILocator.executableURL(named: "codex") else {
            return CLIConnectionCheck(
                canConnect: false,
                isInstalled: false,
                title: "Codex CLI not found",
                message: "Install Codex CLI, then recheck.",
                systemImage: "xmark.circle.fill",
                tint: .red
            )
        }

        let status = await CommandRunner.run(executableURL: executableURL, arguments: ["login", "status"], timeout: 8)
        guard status.exitCode == 0 else {
            return CLIConnectionCheck(
                canConnect: false,
                isInstalled: true,
                title: "Codex CLI not logged in",
                message: "Select Log in to start the official Codex browser flow.",
                systemImage: "exclamationmark.circle.fill",
                tint: .orange
            )
        }

        return CLIConnectionCheck(
            canConnect: true,
            isInstalled: true,
            title: "Codex CLI ready",
            message: "Agent Meter is using the login shared by Codex CLI and the IDE extension.",
            systemImage: "checkmark.circle.fill",
            tint: .green
        )
    }

    private static func claudeCodeCheck() async -> CLIConnectionCheck {
        guard let executableURL = await CLILocator.executableURL(named: "claude") else {
            return CLIConnectionCheck(
                canConnect: false,
                isInstalled: false,
                title: "Claude Code CLI not found",
                message: "Install Claude Code CLI, then recheck.",
                systemImage: "xmark.circle.fill",
                tint: .red
            )
        }

        let status = await CommandRunner.run(executableURL: executableURL, arguments: ["auth", "status"], timeout: 8)
        guard status.exitCode == 0 else {
            return CLIConnectionCheck(
                canConnect: false,
                isInstalled: true,
                title: "Claude Code not logged in",
                message: "Select Log in to start the official Claude browser flow, or run `claude auth login` in a terminal and recheck.",
                systemImage: "exclamationmark.circle.fill",
                tint: .orange
            )
        }

        return CLIConnectionCheck(
            canConnect: true,
            isInstalled: true,
            title: "Claude Code ready",
            message: "Agent Meter is using the login managed by Claude Code.",
            systemImage: "checkmark.circle.fill",
            tint: .green
        )
    }

    private static func firstUsefulLine(in primary: String, fallback: String) -> String? {
        let combined = primary.isEmpty ? fallback : primary
        return combined
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }
}

private final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var data = Data()

    init(_ handle: FileHandle) {
        DispatchQueue.global().async { [self] in
            let collected = handle.readDataToEndOfFile()
            lock.lock()
            data = collected
            lock.unlock()
            finished.signal()
        }
    }

    /// Child processes can keep the pipe open after the main process exits, so the wait is bounded.
    func result(timeout: TimeInterval) -> String {
        _ = finished.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private enum CommandRunner {
    static func run(executableURL: URL, arguments: [String], timeout: TimeInterval) async -> CommandResult {
        await Task.detached {
            runBlocking(executableURL: executableURL, arguments: arguments, timeout: timeout)
        }.value
    }

    private static func runBlocking(executableURL: URL, arguments: [String], timeout: TimeInterval) -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let group = DispatchGroup()

        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment(for: executableURL)
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        group.enter()
        process.terminationHandler = { _ in
            group.leave()
        }

        do {
            try process.run()
        } catch {
            return CommandResult(exitCode: -1, standardOutput: "", standardError: error.localizedDescription)
        }

        // Drain both pipes while the process runs; waiting first can deadlock once a pipe buffer fills.
        let output = PipeCollector(outputPipe.fileHandleForReading)
        let error = PipeCollector(errorPipe.fileHandleForReading)

        let timedOut = group.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
        }

        return CommandResult(
            exitCode: timedOut ? -2 : process.terminationStatus,
            standardOutput: output.result(timeout: 1),
            standardError: error.result(timeout: 1)
        )
    }

    static func environment(for executableURL: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let executableDirectory = executableURL.deletingLastPathComponent().path
        let currentPath = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "\(executableDirectory):\(currentPath)"
        return environment
    }
}

private enum CLILocator {
    private static let cache = LockedCache()

    private final class LockedCache: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [String: URL] = [:]

        subscript(name: String) -> URL? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return urls[name]
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                urls[name] = newValue
            }
        }
    }

    /// Usage is refreshed every minute; remember the CLI location so the login shell is not spawned each time.
    static func executableURL(named name: String) async -> URL? {
        if let cached = cache[name], FileManager.default.isExecutableFile(atPath: cached.path) {
            return cached
        }

        let located: URL?
        if let known = executableURLFromKnownLocations(named: name) {
            located = known
        } else {
            located = await executableURLFromLoginShell(named: name)
        }

        cache[name] = located
        return located
    }

    private static func executableURLFromKnownLocations(named name: String) -> URL? {
        let fileManager = FileManager.default
        let homeURL = fileManager.homeDirectoryForCurrentUser
        var directories = [
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/usr/bin"),
            URL(fileURLWithPath: "/bin"),
            homeURL.appendingPathComponent(".local/bin"),
            homeURL.appendingPathComponent(".claude/local"),
            homeURL.appendingPathComponent(".claude/bin"),
            homeURL.appendingPathComponent(".volta/bin"),
            homeURL.appendingPathComponent(".asdf/shims"),
            homeURL.appendingPathComponent(".local/share/mise/shims"),
            homeURL.appendingPathComponent(".bun/bin")
        ]

        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        directories.append(contentsOf: environmentPath.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
        directories.append(contentsOf: versionManagerBinDirectories(in: homeURL))

        for directory in directories {
            let candidateURL = directory.appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        return extensionBundledExecutableURL(named: name, homeURL: homeURL)
    }

    private static func versionManagerBinDirectories(in homeURL: URL) -> [URL] {
        let fileManager = FileManager.default
        var directories = [
            homeURL.appendingPathComponent(".local/share/fnm/aliases/default/bin")
        ]

        let roots = [
            homeURL.appendingPathComponent(".local/share/fnm/node-versions"),
            homeURL.appendingPathComponent(".nvm/versions/node")
        ]

        for root in roots {
            guard let versions = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for versionURL in versions.sorted(by: newestVersionFirst) {
                if root.lastPathComponent == "node-versions" {
                    directories.append(versionURL.appendingPathComponent("installation/bin"))
                } else {
                    directories.append(versionURL.appendingPathComponent("bin"))
                }
            }
        }

        return directories
    }

    private static func extensionBundledExecutableURL(named name: String, homeURL: URL) -> URL? {
        let fileManager = FileManager.default
        let extensionRoots = [
            homeURL.appendingPathComponent(".vscode/extensions"),
            homeURL.appendingPathComponent(".vscode-insiders/extensions"),
            homeURL.appendingPathComponent(".cursor/extensions")
        ]

        #if arch(arm64)
        let codexPlatformDirectory = "macos-aarch64"
        #else
        let codexPlatformDirectory = "macos-x86_64"
        #endif

        for root in extensionRoots {
            guard let extensions = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            let matchingExtensions = extensions
                .filter { extensionURL in
                    let directoryName = extensionURL.lastPathComponent
                    return name == "codex"
                        ? directoryName.hasPrefix("openai.chatgpt-")
                        : directoryName.hasPrefix("anthropic.claude-code-")
                }
                .sorted(by: newestVersionFirst)

            for extensionURL in matchingExtensions {
                let candidateURL: URL
                if name == "codex" {
                    candidateURL = extensionURL
                        .appendingPathComponent("bin")
                        .appendingPathComponent(codexPlatformDirectory)
                        .appendingPathComponent("codex")
                } else {
                    candidateURL = extensionURL
                        .appendingPathComponent("resources/native-binary/claude")
                }

                if fileManager.isExecutableFile(atPath: candidateURL.path) {
                    return candidateURL
                }
            }
        }

        return nil
    }

    private static func executableURLFromLoginShell(named name: String) async -> URL? {
        let shellURL = URL(fileURLWithPath: "/bin/zsh")
        let result = await CommandRunner.run(
            executableURL: shellURL,
            arguments: ["-lic", "command -v -- \"$1\"", "agent-meter", name],
            timeout: 8
        )

        guard result.exitCode == 0 else {
            return nil
        }

        let fileManager = FileManager.default
        return result.standardOutput
            .split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .reversed()
            .map { URL(fileURLWithPath: $0) }
            .first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    private static func newestVersionFirst(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedDescending
    }
}
