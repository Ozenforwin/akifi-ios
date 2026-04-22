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
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if !viewModel.activeGoals.isEmpty {
                            Section {
                                ForEach(viewModel.activeGoals) { goal in
                                    NavigationLink {
                                        SavingsGoalDetailView(
                                            goal: goal,
                                            contributions: viewModel.contributions[goal.id] ?? [],
                                            progress: viewModel.progress(for: goal),
                                            daysRemaining: viewModel.daysRemaining(for: goal)
                                        ) { amount, type, note in
                                            let accountCurrency = goal.accountId.flatMap { accId in
                                                appViewModel.dataStore.accounts.first(where: { $0.id == accId })?.currency
                                            }
                                            await viewModel.addContribution(
                                                goalId: goal.id,
                                                amount: amount,
                                                type: type,
                                                note: note,
                                                accountCurrency: accountCurrency
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
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            Task { await viewModel.deleteGoal(goal) }
                                        } label: {
                                            Label(String(localized: "common.delete"), systemImage: "trash")
                                        }
                                    }
                                }
                            } header: {
                                Text(String(localized: "savings.active"))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        if !viewModel.completedGoals.isEmpty {
                            Section {
                                ForEach(viewModel.completedGoals) { goal in
                                    SavingsGoalCardView(
                                        goal: goal,
                                        progress: 1.0,
                                        daysRemaining: nil
                                    )
                                    .opacity(0.7)
                                }
                            } header: {
                                Text(String(localized: "savings.completed"))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 120)
                }
            }
        }
        .refreshable {
            await viewModel.load()
        }
        .navigationTitle(String(localized: "savings.title"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.showForm = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task {
            await viewModel.load()
        }
        .sheet(isPresented: $viewModel.showForm) {
            SavingsGoalFormView(accounts: dataStore.accounts) { name, icon, color, amount, deadline, accountId in
                await viewModel.createGoal(
                    name: name, icon: icon, color: color,
                    targetAmount: amount, deadline: deadline, accountId: accountId
                )
            }
            .presentationBackground(.ultraThinMaterial)
        }
    }
}
