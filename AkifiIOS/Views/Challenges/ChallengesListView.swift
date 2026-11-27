import SwiftUI

struct ChallengesListView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var vm = SavingsChallengesViewModel()
    @State private var showForm = false
    @State private var selectedChallenge: SavingsChallenge?

    private var dataStore: DataStore { appViewModel.dataStore }

    var body: some View {
        List {
            if vm.challenges.isEmpty && !vm.isLoading {
                Section {
                    emptyState
                        .listRowBackground(Color.clear)
                }
            } else {
                if !vm.activeChallenges.isEmpty {
                    section(
                        title: String(localized: "challenges.active"),
                        items: vm.activeChallenges
                    )
                }
                if !vm.completedChallenges.isEmpty {
                    section(
                        title: String(localized: "challenges.completed"),
                        items: vm.completedChallenges
                    )
                }
                if !vm.abandonedChallenges.isEmpty {
                    section(
                        title: String(localized: "challenges.abandoned"),
                        items: vm.abandonedChallenges
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .akifiFloatingButtonClearance()
        .navigationTitle(String(localized: "challenges.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showForm = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(String(localized: "challenges.addNew"))
            }
        }
        .task {
            await vm.load()
            await vm.reconcileProgress(transactions: dataStore.transactions, currencyContext: dataStore.currencyContext)
        }
        .refreshable {
            await vm.load()
            await vm.reconcileProgress(transactions: dataStore.transactions, currencyContext: dataStore.currencyContext)
        }
        .sheet(isPresented: $showForm) {
            ChallengeFormView { _ in
                Task {
                    await vm.load()
                    await vm.reconcileProgress(transactions: dataStore.transactions, currencyContext: dataStore.currencyContext)
                }
            }
        }
        .sheet(item: $selectedChallenge) { ch in
            ChallengeDetailView(
                challenge: ch,
                onAbandon: {
                    Task {
                        await vm.abandon(ch)
                        selectedChallenge = nil
                    }
                },
                onDelete: {
                    Task {
                        await vm.delete(ch)
                        selectedChallenge = nil
                    }
                }
            )
        }
    }

    // MARK: - Section

    private func section(title: String, items: [SavingsChallenge]) -> some View {
        Section(title) {
            ForEach(items) { ch in
                Button {
                    selectedChallenge = ch
                } label: {
                    ChallengeCardView(challenge: ch)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        EmptyStateView(
            title: String(localized: "challenges.empty.title"),
            systemImage: "flag.checkered",
            description: String(localized: "challenges.empty.subtitle"),
            actionTitle: String(localized: "challenges.addNew")
        ) {
            showForm = true
        }
    }
}
