import Foundation

/// The accounts whose balance the user hid with the eye on the Home card.
///
/// The carousel owns the toggle (`HiddenBalancesStore`, private to
/// `AccountCarouselView.swift`); this is the same storage — standard
/// defaults, key `akifi-hidden-balances`, an array of account ids — read
/// for the widget snapshot, so a hidden balance is «••••» on the home
/// screen and the Lock Screen too. `HiddenBalancesKeyGuardTests` fails if
/// the two keys drift apart. (The carousel can switch to this type once
/// its 1.6.0 rework lands — it was off limits for the widget work.)
enum HiddenBalances {
    static let defaultsKey = "akifi-hidden-balances"

    static func ids(in defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: defaultsKey) ?? [])
    }
}
