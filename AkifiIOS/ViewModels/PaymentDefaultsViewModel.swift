import Foundation
import Observation

/// Loads all shared accounts the current user belongs to + any stored
/// `user_account_defaults` rows, so `PaymentDefaultsView` can render a
/// per-shared-account picker of "usual source card".
@MainActor
@Observable
final class PaymentDefaultsViewModel {
    var defaults: [String: String] = [:]   // accountId → defaultSourceId
    var isLoading = false
    var errorMessage: String?

    private let repo = UserAccountDefaultsRepository()

    /// Loads the current set of defaults from Supabase and repopulates the
    /// `defaults` dictionary.
    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let rows = try await repo.fetchAll()
            var map: [String: String] = [:]
            for row in rows {
                if let src = row.defaultSourceId {
                    map[row.accountId] = src
                }
            }
            defaults = map
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Stores the user's choice for a given target account. Passing `nil`
    /// for `sourceId` clears the default (target account becomes the source).
    func setDefault(accountId: String, sourceId: String?) async {
        do {
            try await repo.upsert(accountId: accountId, defaultSourceId: sourceId)
            if let sourceId {
                defaults[accountId] = sourceId
            } else {
                defaults.removeValue(forKey: accountId)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
