import Foundation
import Supabase

final class SupabaseManager: Sendable {
    static let shared = SupabaseManager()

    let client: SupabaseClient

    private init() {
        client = SupabaseClient(
            supabaseURL: URL(string: AppConstants.supabaseURL)!,
            supabaseKey: AppConstants.supabaseAnonKey,
            options: .init(
                auth: .init(autoRefreshToken: true, emitLocalSessionAsInitialSession: true)
            )
        )
    }
}
