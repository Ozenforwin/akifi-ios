import SwiftUI

/// Settings screen listing every shared account the user belongs to and
/// a picker for the personal account they usually pay with. Value selected
/// here pre-selects the "Paid from" picker in `TransactionFormView` next
/// time the user creates an expense on that target.
struct PaymentDefaultsView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = PaymentDefaultsViewModel()

    private var dataStore: DataStore { appViewModel.dataStore }
    private var currentUserId: String { dataStore.profile?.id ?? "" }

    /// All accounts visible to us where at least one transaction was made
    /// by someone other than the current user — i.e. "shared" accounts.
    private var sharedAccounts: [Account] {
        let uid = currentUserId
        return dataStore.accounts.filter { acc in
            acc.userId != uid ||
            dataStore.transactions.contains { $0.accountId == acc.id && $0.userId != uid }
        }
    }

    /// Own personal accounts (excluding the currently-iterated target).
    /// Currency mismatch is no longer a filter — cross-currency sources
    /// are valid now (RPC 10-arg overload handles FX per-leg).
    private func personalSources(for target: Account) -> [Account] {
        dataStore.accounts.filter { acc in
            acc.userId == currentUserId && acc.id != target.id
        }
    }

    var body: some View {
        List {
            Section {
                Text(String(localized: "settings.paymentDefaults.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }

            if sharedAccounts.isEmpty {
                Section {
                    Text(String(localized: "settings.paymentDefaults.noShared"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(sharedAccounts) { target in
                    Section(header: Text("\(target.icon) \(target.name)")) {
                        let sources = personalSources(for: target)
                        if sources.isEmpty {
                            Text(String(localized: "tx.paymentSource.hint.currencyMismatch"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker(
                                String(localized: "tx.paymentSource"),
                                selection: Binding<String?>(
                                    get: { viewModel.defaults[target.id] },
                                    set: { newValue in
                                        Task { await viewModel.setDefault(accountId: target.id, sourceId: newValue) }
                                    }
                                )
                            ) {
                                Text(String(localized: "tx.paymentSource.none")).tag(nil as String?)
                                ForEach(sources) { src in
                                    Text("\(src.icon) \(src.name)").tag(src.id as String?)
                                }
                            }
                        }
                    }
                }
            }

            if let err = viewModel.errorMessage {
                Section {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(String(localized: "settings.paymentDefaults"))
        .task {
            await viewModel.load()
        }
    }
}
