import Foundation
import FirebaseAnalytics

/// Centralized analytics for all key user actions
enum AnalyticsService {

    // MARK: - Auth
    static func logSignIn(method: String) {
        Analytics.logEvent(AnalyticsEventLogin, parameters: [AnalyticsParameterMethod: method])
    }

    static func logSignUp(method: String) {
        Analytics.logEvent(AnalyticsEventSignUp, parameters: [AnalyticsParameterMethod: method])
    }

    // MARK: - Transactions
    static func logAddTransaction(type: String, amount: Double, category: String?) {
        Analytics.logEvent("add_transaction", parameters: [
            "type": type,
            "amount": amount,
            "category": category ?? "none"
        ])
    }

    static func logDeleteTransaction() {
        Analytics.logEvent("delete_transaction", parameters: nil)
    }

    // MARK: - Accounts
    static func logCreateAccount() {
        Analytics.logEvent("create_account_bank", parameters: nil)
    }

    // MARK: - Budgets
    static func logCreateBudget(period: String) {
        Analytics.logEvent("create_budget", parameters: ["period": period])
    }

    // MARK: - Savings
    static func logCreateGoal() {
        Analytics.logEvent("create_savings_goal", parameters: nil)
    }

    static func logContribution(type: String, amount: Double) {
        Analytics.logEvent("savings_contribution", parameters: ["type": type, "amount": amount])
    }

    // MARK: - AI Assistant
    static func logAIChat() {
        Analytics.logEvent("ai_chat_sent", parameters: nil)
    }

    static func logAIVoice() {
        Analytics.logEvent("ai_voice_sent", parameters: nil)
    }

    // MARK: - Receipt Scanner
    static func logScanReceipt() {
        Analytics.logEvent("scan_receipt", parameters: nil)
    }

    // MARK: - Import / Export
    static func logImportStatement() {
        Analytics.logEvent("import_statement", parameters: nil)
    }

    static func logExportCSV() {
        Analytics.logEvent("export_csv", parameters: nil)
    }

    // MARK: - Settings
    static func logChangeCurrency(to currency: String) {
        Analytics.logEvent("change_currency", parameters: ["currency": currency])
    }

    static func logChangeLanguage(to language: String) {
        Analytics.logEvent("change_language", parameters: ["language": language])
    }

    // MARK: - Screens
    static func logScreen(_ name: String) {
        Analytics.logEvent(AnalyticsEventScreenView, parameters: [
            AnalyticsParameterScreenName: name
        ])
    }

    // MARK: - Subscriptions
    static func logSubscriptionStatusChange(to status: String) {
        Analytics.logEvent("subscription_status_change", parameters: ["status": status])
    }

    static func logSubscriptionAutoMatch(score: Int) {
        Analytics.logEvent("subscription_auto_match", parameters: ["score": score])
    }

    static func logSubscriptionAutoMatchUndo() {
        Analytics.logEvent("subscription_auto_match_undo", parameters: nil)
    }

    static func logRemindersRescheduled(scheduled: Int, cancelled: Int) {
        Analytics.logEvent("subscription_reminders_rescheduled", parameters: [
            "scheduled": scheduled,
            "cancelled": cancelled
        ])
    }

    // MARK: - Generic

    static func logEvent(_ name: String, params: [String: Any]? = nil) {
        Analytics.logEvent(name, parameters: params)
    }
}
