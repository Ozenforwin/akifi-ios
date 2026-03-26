import Foundation

enum AppConstants {
    static let supabaseURL: String = {
        guard let value = Bundle.main.infoDictionary?["SupabaseURL"] as? String, !value.isEmpty else {
            fatalError("SupabaseURL not found in Info.plist. Check your .xcconfig files.")
        }
        return value
    }()

    static let supabaseAnonKey: String = {
        guard let value = Bundle.main.infoDictionary?["SupabaseAnonKey"] as? String, !value.isEmpty else {
            fatalError("SupabaseAnonKey not found in Info.plist. Check your .xcconfig files.")
        }
        return value
    }()
}
