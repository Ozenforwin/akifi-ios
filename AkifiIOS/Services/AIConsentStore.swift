import Foundation

/// The user's one-time agreement to send their question and financial
/// data to the third-party AI providers behind the assistant (R8, App
/// Review 5.1.2(i)). Stored per user on this device: a second account on
/// the same iPhone is asked again.
///
/// `version` is part of the key — bump it when the providers or the kind
/// of data sent change, and everyone is asked again.
struct AIConsentStore {
    static let version = 1

    /// Providers named on the consent screen. Keep in sync with
    /// supabase/functions/assistant-query (nlg.ts, _shared/openai.ts,
    /// _shared/anthropic.ts).
    static let providers = ["OpenAI", "Anthropic"]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(userId: String) -> String {
        "ai_consent_v\(version)_\(userId.lowercased())"
    }

    func hasConsented(userId: String?) -> Bool {
        guard let userId, !userId.isEmpty else { return false }
        return defaults.object(forKey: Self.key(userId: userId)) != nil
    }

    /// When the user agreed, or nil.
    func consentDate(userId: String) -> Date? {
        defaults.object(forKey: Self.key(userId: userId)) as? Date
    }

    func recordConsent(userId: String, at date: Date = Date()) {
        guard !userId.isEmpty else { return }
        defaults.set(date, forKey: Self.key(userId: userId))
    }

    func revokeConsent(userId: String) {
        defaults.removeObject(forKey: Self.key(userId: userId))
    }
}
