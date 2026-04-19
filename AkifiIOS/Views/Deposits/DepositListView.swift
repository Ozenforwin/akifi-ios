import SwiftUI

/// Top-level deposits screen. Sectioned by status (Active / Matured /
/// Closed). Tap → detail, swipe for delete or early-close actions.
///
/// Entry points: Home shortcut, Settings → Finance → Вклады.
struct DepositListView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = DepositsViewModel()
    @State private var showForm = false
    @State private var pendingClose: Deposit?
    @State private var pendingDelete: Deposit?

    private var dataStore: DataStore { appViewModel.dataStore }
    private var cm: CurrencyManager { appViewModel.currencyManager }

    private var activeDeposits: [Deposit] { viewModel.deposits.filter { $0.status == .active } }
    private var maturedDeposits: [Deposit] { viewModel.deposits.filter { $0.status == .matured } }
    private var closedDeposits: [Deposit] { viewModel.deposits.filter { $0.status == .closedEarly } }

    var body: some View {
        List {
            if viewModel.deposits.isEmpty && !viewModel.isLoading {
                Section {
                    emptyState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            if !activeDeposits.isEmpty {
                Section(String(localized: "deposit.section.active")) {
                    ForEach(activeDeposits) { deposit in
                        rowLink(for: deposit)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    pendingClose = deposit
                                } label: {
                                    Label(String(localized: "deposit.closeEarly"), systemImage: "xmark.seal.fill")
                                }
                                .tint(.orange)
                                Button(role: .destructive) {
                                    pendingDelete = deposit
                                } label: {
                                    Label(String(localized: "common.delete"), systemImage: "trash")
                                }
                            }
                    }
                }
            }

            if !maturedDeposits.isEmpty {
                Section(String(localized: "deposit.section.matured")) {
                    ForEach(maturedDeposits) { deposit in
                        rowLink(for: deposit)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pendingDelete = deposit
                                } label: {
                                    Label(String(localized: "common.delete"), systemImage: "trash")
                                }
                            }
                    }
                }
            }

            if !closedDeposits.isEmpty {
                Section(String(localized: "deposit.section.closed")) {
                    ForEach(closedDeposits) { deposit in
                        rowLink(for: deposit)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pendingDelete = deposit
                                } label: {
                                    Label(String(localized: "common.delete"), systemImage: "trash")
                                }
                            }
                    }
                }
            }

            Color.clear.frame(height: 100)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "deposit.title"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showForm = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
        }
        .task {
            await viewModel.load(dataStore: dataStore)
        }
        .refreshable {
            await viewModel.load(dataStore: dataStore)
        }
        .sheet(isPresented: $showForm) {
            DepositFormView(viewModel: viewModel)
                .presentationBackground(.ultraThinMaterial)
        }
        .alert(
            String(localized: "deposit.closeEarly.confirmTitle"),
            isPresented: .init(
                get: { pendingClose != nil },
                set: { if !$0 { pendingClose = nil } }
            )
        ) {
            Button(String(localized: "common.cancel"), role: .cancel) { pendingClose = nil }
            Button(String(localized: "deposit.closeEarly"), role: .destructive) {
                if let d = pendingClose {
                    Task { await closeEarly(d) }
                }
                pendingClose = nil
            }
        } message: {
            Text(String(localized: "deposit.closeEarly.confirmMessage"))
        }
        .alert(
            String(localized: "deposit.delete.confirmTitle"),
            isPresented: .init(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button(String(localized: "common.cancel"), role: .cancel) { pendingDelete = nil }
            Button(String(localized: "common.delete"), role: .destructive) {
                if let d = pendingDelete {
                    Task { await viewModel.delete(d, dataStore: dataStore) }
                }
                pendingDelete = nil
            }
        } message: {
            Text(String(localized: "deposit.delete.confirmMessage"))
        }
    }

    @ViewBuilder
    private func rowLink(for deposit: Deposit) -> some View {
        NavigationLink {
            DepositDetailView(deposit: deposit, viewModel: viewModel)
        } label: {
            row(for: deposit)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private func row(for deposit: Deposit) -> some View {
        let account = dataStore.accounts.first(where: { $0.id == deposit.accountId })
        let ccy = account.map { CurrencyCode(rawValue: $0.currency.uppercased()) ?? .rub } ?? .rub
        let total = viewModel.liveTotalValue(for: deposit)
        let accrued = viewModel.liveAccruedInterest(for: deposit)
        let days = daysLeft(for: deposit)

        DepositCardView(
            deposit: deposit,
            title: account?.name,
            totalValue: total,
            accrued: accrued,
            currency: ccy,
            daysToMaturity: days
        )
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "percent")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(hex: "#A78BFA"), Color(hex: "#7C3AED")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(String(localized: "deposit.empty.title"))
                .font(.headline)
            Text(String(localized: "deposit.empty.subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showForm = true
            } label: {
                Text(String(localized: "deposit.empty.cta"))
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.accent.opacity(0.16))
                    .foregroundStyle(Color.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 20)
    }

    private func closeEarly(_ deposit: Deposit) async {
        guard let depositAccount = dataStore.accounts.first(where: { $0.id == deposit.accountId }) else {
            return
        }
        let returnTo = dataStore.accounts.first { $0.id == deposit.returnToAccountId }
            ?? dataStore.accounts.first { $0.id != deposit.accountId }
        guard let returnTo else { return }
        do {
            try await viewModel.closeEarly(
                deposit,
                depositAccount: depositAccount,
                returnTo: returnTo,
                dataStore: dataStore
            )
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func daysLeft(for deposit: Deposit) -> Int? {
        guard let endStr = deposit.endDate,
              let end = DepositsViewModel.parseDate(endStr) else { return nil }
        let cal = InterestCalculator.defaultCalendar
        let today = cal.startOfDay(for: Date())
        return cal.dateComponents([.day], from: today, to: end).day
    }
}
