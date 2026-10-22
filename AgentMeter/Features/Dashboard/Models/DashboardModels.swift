import SwiftUI
import Security

enum AgentCredentialService: String {
    case openAI = "openai"
    case claudeCode = "claude-code"
}

enum AgentCredentialStoreError: Error {
    case keychainFailure(OSStatus)
}

protocol AgentCredentialStoring {
    func saveCLILogin(for service: AgentCredentialService) throws
    func deleteConnection(for service: AgentCredentialService) throws
    func hasConnection(for service: AgentCredentialService) -> Bool
}

final class AgentCredentialStore: AgentCredentialStoring {
    static let shared = AgentCredentialStore()

    private let keychainService = "com.agentmeter.credentials"
    private let connectionMethodDefaultsKeyPrefix = "agentmeter.connection-method."

    private init() {}

    func saveCLILogin(for service: AgentCredentialService) throws {
        try deleteStoredSecret(for: service)
        UserDefaults.standard.set("cliLogin", forKey: connectionMethodDefaultsKey(for: service))
    }

    func deleteConnection(for service: AgentCredentialService) throws {
        UserDefaults.standard.removeObject(forKey: connectionMethodDefaultsKey(for: service))
        try deleteStoredSecret(for: service)
    }

    func hasConnection(for service: AgentCredentialService) -> Bool {
        UserDefaults.standard.string(forKey: connectionMethodDefaultsKey(for: service)) == "cliLogin"
    }

    private func deleteStoredSecret(for service: AgentCredentialService) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: service.rawValue
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AgentCredentialStoreError.keychainFailure(status)
        }
    }

    private func connectionMethodDefaultsKey(for service: AgentCredentialService) -> String {
        "\(connectionMethodDefaultsKeyPrefix)\(service.rawValue)"
    }
}

struct CLIConnectionCheck {
    let canConnect: Bool
    let isInstalled: Bool
    let title: String
    let message: String
    let systemImage: String
    let tint: Color
}

enum AgentKind: String, CaseIterable, Identifiable, Codable {
    case codex
    case claudeCode

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claudeCode:
            return "Claude Code"
        }
    }

    var assetName: String {
        switch self {
        case .codex:
            return "CodexIcon"
        case .claudeCode:
            return "ClaudeCodeIcon"
        }
    }

    var tint: Color {
        switch self {
        case .codex:
            return Color(red: 0.32, green: 0.38, blue: 1.0)
        case .claudeCode:
            return Color(red: 0.82, green: 0.36, blue: 0.18)
        }
    }

    var credentialService: AgentCredentialService {
        switch self {
        case .codex:
            return .openAI
        case .claudeCode:
            return .claudeCode
        }
    }

    /// Periods the service is known to report, offered in the menu bar settings even before data arrives.
    var knownPeriods: [AgentUsagePeriod] {
        switch self {
        case .codex:
            return [.week]
        case .claudeCode:
            return [.fiveHours, .week]
        }
    }

    var cliDisplayName: String {
        switch self {
        case .codex:
            return "Codex CLI"
        case .claudeCode:
            return "Claude Code CLI"
        }
    }

    var cliRequirementText: String {
        switch self {
        case .codex:
            return "Uses Codex CLI or the Codex binary bundled with a supported IDE extension."
        case .claudeCode:
            return "Uses the Claude Code login from the terminal or a supported IDE extension. Claude Code CLI must be installed."
        }
    }

    var privacyNoteText: String {
        switch self {
        case .codex:
            return "Uses the official CLI login shared with supported IDE extensions. Agent Meter starts the provider's browser login and never reads or copies access tokens."
        case .claudeCode:
            return "Uses the login Claude Code already has. Agent Meter starts the official `claude auth login` browser flow if needed, reads the token Claude Code keeps in your macOS Keychain only to call Anthropic's usage endpoint, and never writes it to disk or refreshes it itself."
        }
    }
}

enum AgentUsagePeriod: String, CaseIterable, Identifiable, Codable {
    case fiveHours
    case week

    var id: String { rawValue }

    var durationMinutes: Int {
        switch self {
        case .fiveHours: return 300
        case .week: return 10_080
        }
    }

    var displayName: String {
        switch self {
        case .fiveHours: return "5 hours"
        case .week: return "Week"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .fiveHours: return "5h"
        case .week: return "1w"
        }
    }

    static func period(forDurationMinutes durationMinutes: Int) -> AgentUsagePeriod? {
        allCases.first { $0.durationMinutes == durationMinutes }
    }
}

/// One usage bar in the menu bar: a service and one of its periods.
struct MenuBarItemID: Hashable, Identifiable {
    let kind: AgentKind
    let period: AgentUsagePeriod

    var id: String {
        "\(kind.rawValue).\(period.rawValue)"
    }

    var displayName: String {
        "\(kind.displayName) · \(period.displayName)"
    }
}

/// The services' APIs report only a utilization percentage and a reset time, not token counts.
enum MenuBarValueStyle: String, CaseIterable, Identifiable, Codable {
    case hidden
    case usedPercentage
    case usedNumber
    case remainingPercentage
    case remainingNumber
    case resetCountdown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hidden: return "None"
        case .usedPercentage: return "Used (42%)"
        case .usedNumber: return "Used (42)"
        case .remainingPercentage: return "Remaining (58%)"
        case .remainingNumber: return "Remaining (58)"
        case .resetCountdown: return "Time until reset (2h 5m)"
        }
    }

    /// The bar follows the value: it fills with what is left when the value shows what is left.
    var showsRemaining: Bool {
        self == .remainingPercentage || self == .remainingNumber
    }

    func text(for usage: AgentUsageWindow?, now: Date = Date()) -> String? {
        switch self {
        case .hidden:
            return nil
        case .usedPercentage:
            return usage.map { "\($0.usedPercentage)%" } ?? "—"
        case .usedNumber:
            return usage.map { "\($0.usedPercentage)" } ?? "—"
        case .remainingPercentage:
            return usage.map { "\(100 - $0.usedPercentage)%" } ?? "—"
        case .remainingNumber:
            return usage.map { "\(100 - $0.usedPercentage)" } ?? "—"
        case .resetCountdown:
            guard let resetsAt = usage?.resetsAt else {
                return "—"
            }
            return Self.compactDuration(resetsAt.timeIntervalSince(now))
        }
    }

    static func compactDuration(_ interval: TimeInterval) -> String {
        let minutes = max(Int((interval / 60).rounded(.up)), 0)
        if minutes < 60 {
            return "\(minutes)m"
        }
        if minutes < 24 * 60 {
            let remainder = minutes % 60
            return remainder == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(remainder)m"
        }
        let hours = minutes / 60
        let remainder = hours % 24
        return remainder == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(remainder)h"
    }
}

struct MenuBarItemStyle: Equatable, Codable {
    var isEnabled: Bool
    var showsLabel = true
    var showsBar = true
    var value: MenuBarValueStyle = .usedPercentage

    /// Shown out of the box: one bar per service, matching earlier versions.
    static func defaultStyle(for item: MenuBarItemID) -> MenuBarItemStyle {
        MenuBarItemStyle(isEnabled: item.period == item.kind.knownPeriods.first)
    }
}

/// What the menu bar draws: each service's icon followed by its enabled bars.
struct MenuBarGroup: Identifiable, Equatable {
    struct Entry: Identifiable, Equatable {
        let item: MenuBarItemID
        let style: MenuBarItemStyle
        let usage: AgentUsageWindow?

        var id: String { item.id }
    }

    let agent: AgentUsageSnapshot
    let entries: [Entry]

    var id: AgentKind { agent.kind }
}

struct AgentUsageWindow: Identifiable, Equatable {
    let durationMinutes: Int
    let usedPercentage: Int
    let resetsAt: Date?

    var id: Int {
        durationMinutes
    }

    var usedRatio: Double {
        min(max(Double(usedPercentage) / 100, 0), 1)
    }

    var displayName: String {
        switch durationMinutes {
        case 300:
            return "5 hours"
        case 10_080:
            return "7 days"
        default:
            if durationMinutes.isMultiple(of: 1_440) {
                return "\(durationMinutes / 1_440) days"
            }
            if durationMinutes.isMultiple(of: 60) {
                return "\(durationMinutes / 60) hours"
            }
            return "\(durationMinutes) minutes"
        }
    }
}

struct AgentUsageSnapshot: Identifiable, Equatable {
    let kind: AgentKind
    let isConnected: Bool
    let lastUpdated: Date?
    let usageWindows: [AgentUsageWindow]

    init(
        kind: AgentKind,
        isConnected: Bool,
        lastUpdated: Date?,
        usageWindows: [AgentUsageWindow] = []
    ) {
        self.kind = kind
        self.isConnected = isConnected
        self.lastUpdated = lastUpdated
        self.usageWindows = usageWindows
    }

    var id: AgentKind {
        kind
    }

    var name: String {
        kind.displayName
    }

    var tint: Color {
        kind.tint
    }

    var icon: Image {
        Image(kind.assetName)
            .renderingMode(.original)
    }

    func usage(for period: AgentUsagePeriod) -> AgentUsageWindow? {
        usageWindows.first(where: { $0.durationMinutes == period.durationMinutes })
    }
}

protocol AgentUsageProviding {
    func usageSnapshots() async throws -> [AgentUsageSnapshot]
}

struct AgentConnectionEditor: Identifiable {
    let kind: AgentKind

    var id: AgentKind {
        kind
    }
}
