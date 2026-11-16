import Foundation
import Supabase
@preconcurrency import FirebaseMessaging

final class NotificationRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    /// Keychain slot `NotificationDelegate` stores the device's FCM token in.
    static let fcmTokenKeychainKey = "fcmToken"

    /// Sign-out: detach this device's push token from the profile row so
    /// the previous user's pushes stop arriving on this phone. Only clears
    /// the column when it still holds THIS device's token — another device
    /// of the same user may have registered since. Needs the session, so
    /// it must run before the session is removed.
    func unregisterFCMToken() async throws {
        guard let token = KeychainService.loadString(key: Self.fcmTokenKeychainKey) else { return }
        let userId = try await SupabaseManager.shared.currentUserId()
        struct ClearToken: Encodable {
            let fcm_token: String?
            let fcm_token_updated_at: String
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encodeNil(forKey: .fcm_token)
                try c.encode(fcm_token_updated_at, forKey: .fcm_token_updated_at)
            }
            enum CodingKeys: String, CodingKey { case fcm_token, fcm_token_updated_at }
        }
        try await supabase
            .from("profiles")
            .update(ClearToken(fcm_token: nil, fcm_token_updated_at: ISO8601DateFormatter().string(from: Date())))
            .eq("id", value: userId)
            .eq("fcm_token", value: token)
            .execute()
    }

    /// Invalidates the device's FCM token at Firebase so a copy left on the
    /// previous user's profile (offline sign-out, dead session) stops
    /// delivering. Firebase issues a fresh token, which the next sign-in
    /// registers. Best effort, fire-and-forget.
    static func rotateDeviceToken() {
        KeychainService.delete(key: fcmTokenKeychainKey)
        Messaging.messaging().deleteToken { error in
            if let error {
                AppLogger.notifications.info("FCM token rotation failed: \(error.localizedDescription)")
            }
        }
    }

    /// After a sign-in: attach the device's current FCM token to the new
    /// user's profile. `didReceiveRegistrationToken` only fires on launch or
    /// rotation, so a sign-in within a running app would otherwise leave
    /// the new user without pushes until the next launch.
    func registerCurrentDeviceToken() async {
        let fetched: String? = try? await withTimeout(seconds: 10) {
            try await Messaging.messaging().token()
        }
        guard let token = fetched ?? KeychainService.loadString(key: Self.fcmTokenKeychainKey) else { return }
        _ = KeychainService.save(key: Self.fcmTokenKeychainKey, string: token)
        await registerFCMToken(token)
    }

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
            // The server now owns subscription reminders for this device —
            // stop scheduling the duplicate local one (D9).
            NotificationManager.recordServerPushRegistration(userId: userId)
        } catch {
            // Non-critical — retry next launch. Until then the local
            // reminder stays the only one this device gets.
            NotificationManager.recordServerPushRegistration(userId: nil)
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
