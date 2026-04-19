import Foundation
import Combine

/// Local feature-flag store backed by UserDefaults.
///
/// Multi-currency rollout needs a kill-switch so we can ship the new read/write
/// paths alongside the legacy ones and flip between them without a rebuild.
/// Server-side flag tables are intentionally *not* used here — this toggle is
/// per-install, per-device, and primarily a dev/QA control.
@MainActor
final class FeatureFlags: ObservableObject {
    static let shared = FeatureFlags()

    private enum Key: String {
        case multiCurrencyV2 = "ff.multi_currency_v2"
    }

    private let defaults: UserDefaults

    @Published private(set) var multiCurrencyV2: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.multiCurrencyV2 = defaults.bool(forKey: Key.multiCurrencyV2.rawValue)
    }

    func setMultiCurrencyV2(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.multiCurrencyV2.rawValue)
        multiCurrencyV2 = enabled
    }
}
