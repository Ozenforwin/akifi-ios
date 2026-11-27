import Foundation
import FirebaseAnalytics

/// Centralized analytics for all key user actions.
///
/// Privacy contract (R7): events describe *what the user did*, never the
/// money involved. Every event goes through `send`, which keeps only the
/// parameter names in `allowedParameterKeys` — an amount, a category id,
/// a description or a balance is dropped before it reaches Firebase, even
/// if a future call site passes one. The App Store privacy label and
/// PrivacyInfo.xcprivacy declare analytics as product interaction only.
enum AnalyticsService {

    /// Parameter names whose values say nothing about the user's finances
    /// or identity. Add a key only after checking that holds for every
    /// value it can take.
    static let allowedParameterKeys: Set<String> = [
        AnalyticsParameterMethod,
        AnalyticsParameterScreenName,
        "type", "period", "period_type", "target", "status", "score", "days",
        "scheduled", "cancelled", "currency", "language", "count", "mood",
        "field", "shared", "table", "assembled", "expected", "members",
        "diff_bucket",
    ]

    /// Where events go. Firebase in the app; tests capture them.
    nonisolated(unsafe) static var sink: (_ name: String, _ parameters: [String: Any]?) -> Void = { name, parameters in
        Analytics.logEvent(name, parameters: parameters)
    }

    /// `params` without the keys outside the allowlist (nil when nothing
    /// is left).
    static func sanitized(_ params: [String: Any]?) -> [String: Any]? {
        guard let params else { return nil }
        let kept = params.filter { allowedParameterKeys.contains($0.key) }
        if kept.count != params.count {
            let dropped = params.keys.filter { !allowedParameterKeys.contains($0) }.sorted()
            AppLogger.data.warning("Analytics: dropped non-allowlisted parameters \(dropped, privacy: .public)")
        }
        return kept.isEmpty ? nil : kept
    }

    /// Order of magnitude of a money difference in minor units — enough
    /// to tell a rounding kopeck from a missing transaction without
    /// sending the amount.
    static func magnitudeBucket(_ minorUnits: Int64) -> String {
        switch minorUnits.magnitude {
        case 0: "0"
        case 1: "1"
        case 2..<100: "<100"
        case 100..<10_000: "<10k"
        default: "10k+"
        }
    }

    private static func send(_ name: String, _ params: [String: Any]?) {
        sink(name, sanitized(params))
    }

    // MARK: - Auth
    static func logSignIn(method: String) {
        send(AnalyticsEventLogin, [AnalyticsParameterMethod: method])
    }

    static func logSignUp(method: String) {
        send(AnalyticsEventSignUp, [AnalyticsParameterMethod: method])
    }

    // MARK: - Transactions
    static func logAddTransaction(type: String) {
        send("add_transaction", ["type": type])
    }

    static func logDeleteTransaction() {
        send("delete_transaction", nil)
    }

    // MARK: - Accounts
    static func logCreateAccount() {
        send("create_account_bank", nil)
    }

    // MARK: - Budgets
    static func logCreateBudget(period: String) {
        send("create_budget", ["period": period])
    }

    // MARK: - Savings
    static func logCreateGoal() {
        send("create_savings_goal", nil)
    }

    static func logContribution(type: String) {
        send("savings_contribution", ["type": type])
    }

    // MARK: - AI Assistant
    static func logAIChat() {
        send("ai_chat_sent", nil)
    }

    static func logAIVoice() {
        send("ai_voice_sent", nil)
    }

    // MARK: - Receipt Scanner
    static func logScanReceipt() {
        send("scan_receipt", nil)
    }

    // MARK: - Import / Export
    static func logImportStatement() {
        send("import_statement", nil)
    }

    static func logExportCSV() {
        send("export_csv", nil)
    }

    // MARK: - Settings
    static func logChangeCurrency(to currency: String) {
        send("change_currency", ["currency": currency])
    }

    static func logChangeLanguage(to language: String) {
        send("change_language", ["language": language])
    }

    // MARK: - Screens
    static func logScreen(_ name: String) {
        send(AnalyticsEventScreenView, [AnalyticsParameterScreenName: name])
    }

    // MARK: - Subscriptions
    static func logSubscriptionStatusChange(to status: String) {
        send("subscription_status_change", ["status": status])
    }

    static func logSubscriptionAutoMatch(score: Int) {
        send("subscription_auto_match", ["score": score])
    }

    static func logSubscriptionAutoMatchUndo() {
        send("subscription_auto_match_undo", nil)
    }

    static func logRemindersRescheduled(scheduled: Int, cancelled: Int) {
        send("subscription_reminders_rescheduled", [
            "scheduled": scheduled,
            "cancelled": cancelled
        ])
    }

    // MARK: - Generic

    static func logEvent(_ name: String, params: [String: Any]? = nil) {
        send(name, params)
    }
}
