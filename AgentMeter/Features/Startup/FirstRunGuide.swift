import Foundation

/// Decides whether to open Settings by itself so a first-time user is not left with only an icon
/// in the menu bar. It fires at most once per installation: after that, opening Settings is the
/// user's choice, even if they later remove every account.
struct FirstRunGuide {
    private static let didEvaluateKey = "agentmeter.first-run-guide.evaluated"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns whether Settings should open now, and records that the guide has been considered.
    /// People who already added an account (for example, updating from an earlier version) are
    /// never interrupted.
    func shouldOpenSettings(hasAccount: Bool) -> Bool {
        guard !defaults.bool(forKey: Self.didEvaluateKey) else {
            return false
        }

        defaults.set(true, forKey: Self.didEvaluateKey)
        return !hasAccount
    }
}
