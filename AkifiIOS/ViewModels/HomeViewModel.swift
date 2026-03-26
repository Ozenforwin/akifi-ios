import Foundation

@Observable @MainActor
final class HomeViewModel {
    var selectedAccountIndex: Int = 0

    func selectedAccount(from accounts: [Account]) -> Account? {
        guard accounts.indices.contains(selectedAccountIndex) else { return nil }
        return accounts[selectedAccountIndex]
    }
}
