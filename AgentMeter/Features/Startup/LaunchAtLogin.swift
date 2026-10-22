import Foundation
import ServiceManagement

/// The part of `SMAppService` the app uses, so the login item logic can be tested without
/// touching the real system.
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

/// Starts Agent Meter at login. A menu bar meter is only useful while it is running.
@MainActor
final class LaunchAtLogin: ObservableObject {
    private static let didApplyDefaultKey = "agentmeter.launch-at-login.default-applied"

    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?

    private let service: LoginItemService
    private let defaults: UserDefaults

    /// On when the app will start at login. A login item waiting for approval in System Settings counts
    /// as on, because the user has already asked for it.
    var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    var needsApproval: Bool {
        status == .requiresApproval
    }

    init(
        service: LoginItemService = SMAppService.mainApp,
        defaults: UserDefaults = .standard,
        bundlePath: String = Bundle.main.bundlePath
    ) {
        self.service = service
        self.defaults = defaults
        status = service.status
        applyDefaultOnFirstLaunch(bundlePath: bundlePath)
    }

    func setEnabled(_ isEnabled: Bool) {
        errorMessage = nil

        do {
            if isEnabled {
                if status != .enabled {
                    try service.register()
                }
            } else if status == .enabled || status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            errorMessage = isEnabled
                ? "Could not turn on Launch at login."
                : "Could not turn off Launch at login."
        }

        refresh()
    }

    /// Re-reads the status, which can change in System Settings while the app is running.
    func refresh() {
        status = service.status
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// The first time an installed copy runs, turn Launch at login on once; after that the choice is
    /// the user's. Development builds run from Xcode's build folder are left alone, so they never
    /// end up registered as a login item.
    private func applyDefaultOnFirstLaunch(bundlePath: String) {
        guard !defaults.bool(forKey: Self.didApplyDefaultKey) else {
            return
        }

        let applicationsDirectories = [
            "/Applications/",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/"
        ]
        guard applicationsDirectories.contains(where: bundlePath.hasPrefix) else {
            return
        }

        defaults.set(true, forKey: Self.didApplyDefaultKey)
        if status == .notRegistered {
            setEnabled(true)
        }
    }
}
