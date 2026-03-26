import SwiftUI

struct BudgetsTabView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = BudgetsViewModel()

    private var dataStore: DataStore { appViewModel.dataStore }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.budgets.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.budgets.isEmpty {
                    ContentUnavailableView(
                        "Нет бюджетов",
                        systemImage: "wallet.bifold.fill",
                        description: Text("Создайте бюджет, чтобы контролировать расходы")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(viewModel.budgets) { budget in
                                BudgetCardView(
                                    budget: budget,
                                    spent: viewModel.spent(for: budget, transactions: dataStore.transactions),
                                    progress: viewModel.progress(for: budget, transactions: dataStore.transactions),
                                    remaining: viewModel.remaining(for: budget, transactions: dataStore.transactions),
                                    periodLabel: viewModel.periodLabel(for: budget),
                                    categories: dataStore.categories
                                )
                                .contextMenu {
                                    Button(role: .destructive) {
                                        Task { await viewModel.deleteBudget(budget) }
                                    } label: {
                                        Label("Удалить", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .refreshable {
                await viewModel.load()
            }
            .navigationTitle("Бюджеты")
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
                BudgetFormView(
                    categories: dataStore.categories,
                    accounts: dataStore.accounts
                ) { name, amount, period, categories, accountId, rollover, threshold in
                    await viewModel.createBudget(
                        name: name,
                        amount: amount,
                        period: period,
                        categories: categories,
                        accountId: accountId,
                        rollover: rollover,
                        alertThreshold: threshold
                    )
                }
            }
        }
    }
}
