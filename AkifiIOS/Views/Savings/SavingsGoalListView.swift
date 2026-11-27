import SwiftUI

struct SavingsGoalListView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = SavingsViewModel()

    private var dataStore: DataStore { appViewModel.dataStore }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.goals.isEmpty {
                LoadingView()
            } else if viewModel.goals.isEmpty {
                EmptyStateView(
                    title: String(localized: "savings.noGoals"),
                    systemImage: "target",
                    description: String(localized: "savings.noGoals.description"),
                    actionTitle: String(localized: "common.create")
                ) {
                    viewModel.showForm = true
                }
            } else {
                List {
                    if !viewModel.activeGoals.isEmpty {
                        Section(String(localized: "savings.active")) {
                            ForEach(viewModel.activeGoals) { goal in
                                NavigationLink {
                                    SavingsGoalDetailView(
                                        goal: goal,
                                        contributions: viewModel.contributions[goal.id] ?? [],
                                        progress: viewModel.progress(for: goal),
                                        daysRemaining: viewModel.daysRemaining(for: goal)
                                    ) { amount, type, note, counterId in
                                        let accounts = appViewModel.dataStore.accounts
                                        try await viewModel.addContribution(
                                            goalId: goal.id,
                                            amount: amount,
                                            type: type,
                                            note: note,
                                            linkedAccount: goal.accountId.flatMap { id in accounts.first { $0.id == id } },
                                            counterAccount: counterId.flatMap { id in accounts.first { $0.id == id } },
                                            currencyManager: appViewModel.currencyManager
                                        )
                                    }
                                    .task(id: goal.id) {
                                        await viewModel.loadContributions(for: goal.id)
                                    }
                                } label: {
                                    SavingsGoalCardView(
                                        goal: goal,
                                        progress: viewModel.progress(for: goal),
                                        daysRemaining: viewModel.daysRemaining(for: goal)
                                    )
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        Task { await viewModel.deleteGoal(goal) }
                                    } label: {
                                        Label(String(localized: "common.delete"), systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }

                    if !viewModel.completedGoals.isEmpty {
                        Section(String(localized: "savings.completed")) {
                            ForEach(viewModel.completedGoals) { goal in
                                SavingsGoalCardView(
                                    goal: goal,
                                    progress: 1.0,
                                    daysRemaining: nil
                                )
                                .opacity(0.7)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .akifiFloatingButtonClearance()
            }
        }
        .refreshable {
            await viewModel.load()
        }
        .navigationTitle(String(localized: "savings.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.showForm = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(String(localized: "savings.newGoal"))
            }
        }
        .task {
            // Contributions with a linked account go through DataStore's
            // offline queue instead of a bare insert (Y10).
            viewModel.dataStore = appViewModel.dataStore
            await viewModel.load()
        }
        .alert(
            String(localized: "common.error"),
            isPresented: Binding(
                get: { viewModel.error != nil },
                set: { if !$0 { viewModel.error = nil } }
            )
        ) {
            Button(String(localized: "common.ok"), role: .cancel) {}
        } message: {
            Text(viewModel.error ?? "")
        }
        .sheet(isPresented: $viewModel.showForm) {
            SavingsGoalFormView(accounts: dataStore.accounts) { draft in
                try await viewModel.createGoal(
                    name: draft.name, icon: draft.icon, color: draft.color,
                    targetAmount: draft.targetAmount, deadline: draft.deadline,
                    accountId: draft.accountId, interest: draft.interest
                )
            }
        }
    }
}
