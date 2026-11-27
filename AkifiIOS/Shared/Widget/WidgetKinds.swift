import Foundation

/// Widget kind identifiers — shared so the app reloads exactly the widgets
/// whose data changed (`SharedSnapshotWriter`). Never rename one: a kind is
/// how iOS finds the widgets a user already placed.
enum AkifiWidgetKind {
    static let balance = "ru.akifi.widget.balance"
    static let dailyLimit = "ru.akifi.widget.dailyLimit"
    static let streak = "ru.akifi.widget.streak"
    static let daySummary = "ru.akifi.widget.daySummary"
    /// «Счёт» — one account, configurable (1.6.0).
    static let account = "ru.akifi.widget.account"
    /// «Быстрая запись» — quick-entry buttons and «Повторить» (1.6.0).
    static let quickAdd = "ru.akifi.widget.quickAdd"

    static let all: Set<String> = [balance, dailyLimit, streak, daySummary, account, quickAdd]
}
