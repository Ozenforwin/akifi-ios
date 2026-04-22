import SwiftUI

struct ChallengesListView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var vm = SavingsChallengesViewModel()
    @State private var showForm = false
    @State private var selectedChallenge: SavingsChallenge?

    private var dataStore: DataStore { appViewModel.dataStore }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if vm.challenges.isEmpty && !vm.isLoading {
                    emptyState
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
                Color.clear.frame(height: 60)
            }
            .padding(.horizontal)
            .padding(.top, 12)
        }
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
            .presentationBackground(.ultraThinMaterial)
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
            .presentationBackground(.ultraThinMaterial)
        }
    }

    // MARK: - Section

    private func section(title: String, items: [SavingsChallenge]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(1)
            VStack(spacing: 10) {
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
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("🎯").font(.system(size: 52))
            Text(String(localized: "challenges.empty.title"))
                .font(.headline)
            Text(String(localized: "challenges.empty.subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                showForm = true
            } label: {
                Label(String(localized: "challenges.addNew"), systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.accent)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}
