import Foundation

@Observable @MainActor
final class HomeViewModel {
    var selectedAccountIndex: Int = 0

    func selectedAccount(from accounts: [Account]) -> Account? {
        guard accounts.indices.contains(selectedAccountIndex) else { return nil }
        return accounts[selectedAccountIndex]
    }

    // MARK: - Account from a widget (akifi://account?id=)

    /// What to do with the account a widget asked for.
    enum PendingAccountOutcome: Equatable {
        /// Select this carousel index.
        case select(Int)
        /// No money account has that id (deleted, a «Долги» account,
        /// someone else's): drop the request, keep the selection.
        case ignore
        /// The accounts aren't there yet (cold start, a load in flight).
        case wait
    }

    /// Where `id` is in the carousel (`dataStore.accounts`: money accounts
    /// only, in the carousel's order). Case-insensitive like DB UUIDs.
    nonisolated static func carouselIndex(ofAccount id: String, in accounts: [Account]) -> Int? {
        accounts.firstIndex { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    nonisolated static func outcome(forAccount id: String, in accounts: [Account], isLoading: Bool) -> PendingAccountOutcome {
        if let index = carouselIndex(ofAccount: id, in: accounts) { return .select(index) }
        return accounts.isEmpty || isLoading ? .wait : .ignore
    }

    /// Applies a widget's account request. Returns true when it is settled
    /// (selected or ignored) and can be cleared.
    func applyPendingAccount(_ id: String, accounts: [Account], isLoading: Bool) -> Bool {
        switch Self.outcome(forAccount: id, in: accounts, isLoading: isLoading) {
        case .select(let index):
            selectedAccountIndex = index
            return true
        case .ignore:
            return true
        case .wait:
            return false
        }
    }
}
