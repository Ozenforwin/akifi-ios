import Foundation
import Supabase

final class FeatureFlagRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    func isEnabled(_ flag: String) async -> Bool {
        do {
            let result: FeatureFlag = try await supabase
                .from("feature_flags")
                .select()
                .eq("key", value: flag)
                .single()
                .execute()
                .value
            return result.enabled
        } catch {
            return false
        }
    }

    func fetchAll() async -> [String: Bool] {
        do {
            let flags: [FeatureFlag] = try await supabase
                .from("feature_flags")
                .select()
                .execute()
                .value
            return Dictionary(uniqueKeysWithValues: flags.map { ($0.key, $0.enabled) })
        } catch {
            return [:]
        }
    }
}

struct FeatureFlag: Codable, Sendable {
    let key: String
    let enabled: Bool
    let description: String?
}
