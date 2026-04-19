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
                periodMenu
            }

            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if viewModel.balances.isEmpty {
                // Nothing to settle in this period — skip history too,
                // since past settlements without their source transactions
                // are orphans (e.g. user marked a debt done, then deleted
                // all the expenses). Showing them with no context is just
                // noise.
                emptyState
            } else {
                balancesList
                if !viewModel.suggestions.isEmpty {
                    Divider().padding(.vertical, 4)
                    suggestionsList
                }
                if !viewModel.pastSettlementsForCurrentPeriod.isEmpty {
                    Divider().padding(.vertical, 4)
                    historyList
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
    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(String(localized: "settlement.empty.title"))
                .font(.subheadline.weight(.medium))
            Text(String(localized: "settlement.empty.body"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var periodMenu: some View {
        Menu {
            Picker(selection: Binding(
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
            } label: {
                EmptyView()
            }
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(periodLabel(viewModel.selectedPeriod))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(Capsule())
        }
    }

    private func periodLabel(_ p: SettlementPeriod) -> String {
        switch p {
        case .thisMonth: return String(localized: "settlement.period.thisMonth")
        case .lastMonth: return String(localized: "settlement.period.lastMonth")
        case .quarter: return String(localized: "settlement.period.quarter")
        case .ytd: return String(localized: "settlement.period.ytd")
        case .custom: return String(localized: "settlement.period.thisMonth")
        }
    }

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
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "settlement.suggestionsHeader"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ForEach(viewModel.suggestions) { s in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(name(for: s.fromUserId))
                            .font(.subheadline.weight(.medium))
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(name(for: s.toUserId))
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(cm.formatAmount(s.amount.displayAmount))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                    }

                    Button {
                        Task {
                            await viewModel.markSettled(
                                suggestion: s,
                                sharedAccountId: sharedAccountId,
                                currency: currency,
                                dataStore: dataStore
                            )
                        }
                    } label: {
                        Text(String(localized: "settlement.markSettled"))
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.accent.opacity(0.15))
                            .foregroundStyle(Color.accent)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    /// Closed settlements for the current period. Swipe a row → Cancel
    /// deletes the settlement row in DB, which reopens the debt on next
    /// load. Only the user who created the settlement can delete (RLS).
    @ViewBuilder
    private var historyList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "settlement.historyHeader"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ForEach(viewModel.pastSettlementsForCurrentPeriod) { s in
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(name(for: s.fromUserId))
                        .font(.subheadline)
                    Image(systemName: "arrow.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(name(for: s.toUserId))
                        .font(.subheadline)
                    Spacer()
                    Text(cm.formatAmount(s.amount.displayAmount))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        Task {
                            await viewModel.cancelSettlement(
                                s,
                                sharedAccountId: sharedAccountId,
                                dataStore: dataStore
                            )
                        }
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "settlement.cancelSettled"))
                }
                .padding(.vertical, 4)
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

    /// Compact signed amount — "+1 346,29 ₽" or "−1 346,29 ₽".
    /// Long explainer text ("вложил больше доли") was cramping the card
    /// at member-name-widths; color-coded signed amount + header
    /// "Предлагаем свести" conveys the same info without wrapping.
    private func deltaLabel(for b: SettlementCalculator.MemberBalance) -> String {
        let amount = cm.formatAmount(abs(b.delta).displayAmount)
        if b.delta == 0 {
            return String(localized: "settlement.balance.even")
        }
        let sign = b.delta > 0 ? "+" : "−"
        return "\(sign)\(amount)"
    }

    private func deltaColor(for b: SettlementCalculator.MemberBalance) -> Color {
        if b.delta > 0 { return .income }
        if b.delta < 0 { return .expense }
        return .secondary
    }
}
