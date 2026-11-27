import Foundation

/// The currency a money form takes its amount in, and whether the USER chose
/// it (M4).
///
/// Forms follow the selected account's currency until the user picks one
/// themselves. The old flag was set from `onChange(of: selectedCurrency)`,
/// which also fires for the form's OWN programmatic sync — so the first
/// account switch marked the currency as "picked by the user" and the
/// second one no longer synced: «Карта USD» → «Наличные ₽» kept $, and
/// "500" went in as 500 USD ≈ 41 300 ₽. Now only `userSelected(_:)` — called
/// from the picker's setter, nowhere else — sets the flag.
struct EntryCurrencyState: Equatable, Sendable {
    private(set) var currency: CurrencyCode
    private(set) var userPicked = false

    init(_ currency: CurrencyCode) {
        self.currency = currency
    }

    /// The user picked `currency` in the picker. Sticks across account
    /// switches.
    mutating func userSelected(_ currency: CurrencyCode) {
        self.currency = currency
        userPicked = true
    }

    /// The form's account changed: follow its currency unless the user has
    /// picked one.
    mutating func follow(accountCurrency: CurrencyCode?) {
        guard !userPicked, let accountCurrency else { return }
        currency = accountCurrency
    }

    /// Programmatic prefill (form opened, editing an existing row). Never
    /// counts as the user's choice.
    mutating func load(_ currency: CurrencyCode) {
        self.currency = currency
    }
}
