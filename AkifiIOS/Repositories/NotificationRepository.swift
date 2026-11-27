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
            .update(ClearToken(fcm_token: nil, fcm_token_updated_at: AppDateFormatters.nowTimestamp()))
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
                    "fcm_token_updated_at": AppDateFormatters.nowTimestamp(),
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

    // MARK: - Notification settings (N5)
    //
    // `notification_settings` (one row per user) is what smart-notifications
    // obeys. The screen used to keep its own copy in @AppStorage — per
    // device, not per user — and upsert it on every open: switching pushes
    // off on one phone was undone by opening the screen on another, and a
    // second account on the same phone got the first one's settings.

    /// The signed-in user's row, or nil when they have none yet.
    func fetchSettings() async throws -> NotificationSettings? {
        let userId = try await SupabaseManager.shared.currentUserId()
        // bounded-fetch: one row per user (user_id is the primary key)
        let rows: [NotificationSettings] = try await supabase
            .from("notification_settings")
            .select(NotificationSettings.columns)
            .eq("user_id", value: userId)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// Writes the user's choice (after a change on the screen).
    func saveSettings(_ settings: NotificationSettings) async throws {
        let userId = try await SupabaseManager.shared.currentUserId()
        try await supabase
            .from("notification_settings")
            .upsert(NotificationSettings.Row(userId: userId, settings: settings), onConflict: "user_id")
            .execute()
    }

    /// First visit without a row: store the defaults the screen shows (the
    /// server skips users without a row). Insert-only — a row created
    /// meanwhile by another device is never overwritten.
    func createSettingsIfMissing(_ settings: NotificationSettings) async throws {
        let userId = try await SupabaseManager.shared.currentUserId()
        try await supabase
            .from("notification_settings")
            .upsert(
                NotificationSettings.Row(userId: userId, settings: settings),
                onConflict: "user_id",
                ignoreDuplicates: true
            )
            .execute()
    }
}

/// Last known settings per USER on this device (N5): shown instantly and
/// offline, and read by the local notifications this device schedules
/// itself (weekly digest, N2). The server row stays the source of truth.
enum NotificationPreferencesCache {
    private static func settingsKey(_ userId: String) -> String { "notifications.settings.\(userId.lowercased())" }
    private static func digestKey(_ userId: String) -> String { "notifications.digestOptIn.\(userId.lowercased())" }

    static func settings(userId: String, defaults: UserDefaults = .standard) -> NotificationSettings? {
        guard let data = defaults.data(forKey: settingsKey(userId)) else { return nil }
        return try? JSONDecoder().decode(NotificationSettings.self, from: data)
    }

    static func store(_ settings: NotificationSettings, userId: String, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: settingsKey(userId))
    }

    /// `ai_user_settings.digest_opt_in` as last seen; false when unknown
    /// (the server sends the digest only on an explicit opt-in).
    static func digestOptIn(userId: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: digestKey(userId))
    }

    static func storeDigestOptIn(_ value: Bool, userId: String, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: digestKey(userId))
    }
}
