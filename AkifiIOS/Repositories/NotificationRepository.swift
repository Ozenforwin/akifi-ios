import Foundation
import Supabase

final class NotificationRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    /// Save FCM token to user profile
    func registerFCMToken(_ token: String) async {
        do {
            let userId = try await SupabaseManager.shared.currentUserId()
            try await supabase
                .from("profiles")
                .update([
                    "fcm_token": token,
                    "fcm_token_updated_at": ISO8601DateFormatter().string(from: Date()),
                    "notification_platform": "ios"
                ])
                .eq("id", value: userId)
                .execute()
        } catch {
            // Non-critical — retry next launch
        }
    }

    /// Sync notification settings to server
    func syncSettings(
        enabled: Bool,
        budgetWarnings: Bool,
        largeExpenses: Bool,
        inactivity: Bool,
        savingsMilestones: Bool,
        weeklyPace: Bool,
        largeExpenseThreshold: Int,
        budgetWarningPercent: Int
    ) async {
        do {
            let userId = try await SupabaseManager.shared.currentUserId()

            struct SettingsInput: Encodable {
                let user_id: String
                let enabled: Bool
                let budget_warnings: Bool
                let large_expenses: Bool
                let inactivity: Bool
                let savings_milestones: Bool
                let weekly_pace: Bool
                let large_expense_threshold: Int
                let budget_warning_percent: Int
            }

            let input = SettingsInput(
                user_id: userId,
                enabled: enabled,
                budget_warnings: budgetWarnings,
                large_expenses: largeExpenses,
                inactivity: inactivity,
                savings_milestones: savingsMilestones,
                weekly_pace: weeklyPace,
                large_expense_threshold: largeExpenseThreshold,
                budget_warning_percent: budgetWarningPercent
            )

            try await supabase
                .from("notification_settings")
                .upsert(input)
                .execute()
        } catch {
            // Non-critical
        }
    }
}
