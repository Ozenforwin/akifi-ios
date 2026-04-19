import SwiftUI

/// Embeddable "who owes whom" card for a shared account.
///
/// Displays:
/// - A segmented period picker
/// - One row per member with their net delta, colour-coded
/// - A list of settlement suggestions with "Mark as settled" buttons
/// - An empty state when there are no transactions in the selected period
struct AccountSettlementCardView: View {
    let sharedAccountId: String
    let currency: String
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = SettlementViewModel()

    private var dataStore: DataStore { appViewModel.dataStore }
    private var cm: CurrencyManager { appViewModel.currencyManager }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(String(localized: "settlement.title"), systemImage: "scalemass.fill")
                    .font(.headline)
                Spacer()
            }

            Picker(String(localized: "settlement.period"), selection: Binding(
                get: { viewModel.selectedPeriod },
                set: { newValue in
                    viewModel.selectedPeriod = newValue
                    Task { await viewModel.load(sharedAccountId: sharedAccountId, dataStore: dataStore) }
                }
            )) {
                Text(String(localized: "settlement.period.thisMonth")).tag(SettlementPeriod.thisMonth)
                Text(String(localized: "settlement.period.lastMonth")).tag(SettlementPeriod.lastMonth)
                Text(String(localized: "settlement.period.quarter")).tag(SettlementPeriod.quarter)
                Text(String(localized: "settlement.period.ytd")).tag(SettlementPeriod.ytd)
            }
            .pickerStyle(.segmented)

            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if viewModel.balances.isEmpty {
                Text(String(localized: "settlement.empty"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                balancesList
                if !viewModel.suggestions.isEmpty {
                    Divider().padding(.vertical, 4)
                    suggestionsList
                }
            }

            if let err = viewModel.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task(id: sharedAccountId) {
            await viewModel.load(sharedAccountId: sharedAccountId, dataStore: dataStore)
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var balancesList: some View {
        VStack(spacing: 8) {
            ForEach(viewModel.balances) { b in
                HStack {
                    Text(name(for: b.userId))
                        .font(.subheadline)
                    Spacer()
                    Text(deltaLabel(for: b))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(deltaColor(for: b))
                }
            }
        }
    }

    @ViewBuilder
    private var suggestionsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(viewModel.suggestions) { s in
                HStack(alignment: .center) {
                    let from = name(for: s.fromUserId)
                    let to = name(for: s.toUserId)
                    let amount = cm.formatAmount(s.amount.displayAmount)
                    Text(String(format: String(localized: "settlement.suggestion"), from, to, amount))
                        .font(.subheadline)
                    Spacer()
                    Button {
                        Task {
                            await viewModel.markSettled(
                                suggestion: s,
                                sharedAccountId: sharedAccountId,
                                currency: currency
                            )
                        }
                    } label: {
                        Text(String(localized: "settlement.markSettled"))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.accent.opacity(0.15))
                            .foregroundStyle(Color.accent)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Helpers

    private func name(for userId: String) -> String {
        if let profile = dataStore.profilesMap[userId], let name = profile.fullName, !name.isEmpty {
            return name
        }
        if userId == dataStore.profile?.id {
            return dataStore.profile?.fullName ?? String(localized: "common.you")
        }
        return String(userId.prefix(6))
    }

    private func deltaLabel(for b: SettlementCalculator.MemberBalance) -> String {
        let amount = cm.formatAmount(abs(b.delta).displayAmount)
        if b.delta == 0 {
            return String(localized: "settlement.balance.even")
        }
        if b.delta > 0 {
            return String(format: String(localized: "settlement.balance.positive"), amount)
        }
        return String(format: String(localized: "settlement.balance.negative"), amount)
    }

    private func deltaColor(for b: SettlementCalculator.MemberBalance) -> Color {
        if b.delta > 0 { return .income }
        if b.delta < 0 { return .expense }
        return .secondary
    }
}
