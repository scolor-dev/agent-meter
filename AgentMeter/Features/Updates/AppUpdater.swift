import Combine
import Foundation
import Sparkle

/// Where this copy of Agent Meter came from. Updates go through Sparkle either way; this only
/// decides which manual update instructions to show.
enum InstallSource: Equatable {
    case homebrew
    case direct

    static let caskToken = "agent-meter"
    static let homebrewUpgradeCommand = "brew upgrade --cask --greedy \(caskToken)"
    static let releasesURL = URL(string: "https://github.com/scolor-dev/agent-meter/releases/latest")!

    static func detect(
        caskroomDirectories: [String] = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> InstallSource {
        let isCaskInstalled = caskroomDirectories.contains { fileExists("\($0)/\(caskToken)") }
        return isCaskInstalled ? .homebrew : .direct
    }
}

/// Wraps Sparkle so the menu and the settings window can share one updater.
@MainActor
final class AppUpdater: ObservableObject {
    let installSource: InstallSource
    let currentVersion: String

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false

    private let controller: SPUStandardUpdaterController?
    private var observations: [AnyCancellable] = []

    /// Sparkle refuses to run without the public EdDSA key (SPARKLE_PUBLIC_ED_KEY in the build settings).
    var isAvailable: Bool {
        controller != nil
    }

    init(bundle: Bundle = .main) {
        installSource = InstallSource.detect()
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

        let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !publicKey.isEmpty, !publicKey.hasPrefix("$(") else {
            controller = nil
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller

        let updater = controller.updater
        observations = [
            updater.publisher(for: \.canCheckForUpdates)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.canCheckForUpdates = $0 },
            updater.publisher(for: \.automaticallyChecksForUpdates)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.automaticallyChecksForUpdates = $0 },
            updater.publisher(for: \.automaticallyDownloadsUpdates)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.automaticallyDownloadsUpdates = $0 }
        ]
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ isEnabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = isEnabled
    }

    func setAutomaticallyDownloadsUpdates(_ isEnabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = isEnabled
    }
}
