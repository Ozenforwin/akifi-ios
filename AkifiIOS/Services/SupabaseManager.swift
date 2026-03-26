import Foundation
import Supabase

@Observable
final class SupabaseManager: @unchecked Sendable {
    static let shared = SupabaseManager()

    let client: SupabaseClient

    private init() {
        client = SupabaseClient(
            supabaseURL: URL(string: AppConstants.supabaseURL)!,
            supabaseKey: AppConstants.supabaseAnonKey
        )
    }
}
