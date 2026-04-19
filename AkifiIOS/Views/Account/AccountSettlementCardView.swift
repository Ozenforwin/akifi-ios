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
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .shadow(color: .primary.opacity(0.05), radius: 10, x: 0, y: 3)
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
                    HapticManager.selection()
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
        VStack(spacing: 6) {
            ForEach(Array(viewModel.balances.enumerated()), id: \.element.id) { index, b in
                HStack(spacing: 12) {
                    memberAvatar(for: b.userId, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name(for: b.userId))
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(deltaCaption(for: b))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(deltaLabel(for: b))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(deltaColor(for: b))
                }
                .padding(.vertical, 6)
                if index < viewModel.balances.count - 1 {
                    Divider().opacity(0.5)
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
                VStack(alignment: .leading, spacing: 10) {
                    // Row 1: From → To with avatar bubbles + amount on the right.
                    HStack(spacing: 8) {
                        memberAvatar(for: s.fromUserId, size: 26)
                        Text(name(for: s.fromUserId))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        memberAvatar(for: s.toUserId, size: 26)
                        Text(name(for: s.toUserId))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        Text(cm.formatAmount(s.amount.displayAmount))
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(Color.accent)
                    }

                    Button {
                        HapticManager.medium()
                        Task {
                            await viewModel.markSettled(
                                suggestion: s,
                                sharedAccountId: sharedAccountId,
                                currency: currency,
                                dataStore: dataStore
                            )
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                            Text(String(localized: "settlement.markSettled"))
                                .font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            LinearGradient(
                                colors: [Color.accent, Color.accent.opacity(0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.accent.opacity(0.15), lineWidth: 0.5)
                )
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
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.15))
                            .frame(width: 22, height: 22)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.green)
                    }
                    Text(name(for: s.fromUserId))
                        .font(.subheadline)
                        .lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(name(for: s.toUserId))
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer()
                    Text(cm.formatAmount(s.amount.displayAmount))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        HapticManager.light()
                        Task {
                            await viewModel.cancelSettlement(
                                s,
                                sharedAccountId: sharedAccountId,
                                dataStore: dataStore
                            )
                        }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(Circle())
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

    /// Small circular badge — photo when we have one, otherwise initials
    /// over a tinted background. Mirrors the treatment used in
    /// `TransactionRowView` so members read consistently across the app.
    @ViewBuilder
    private func memberAvatar(for userId: String, size: CGFloat = 28) -> some View {
        let profile = dataStore.profilesMap[userId]
        ZStack {
            if let urlStr = profile?.avatarUrl, let url = URL(string: urlStr) {
                CachedAsyncImage(url: url) {
                    initialsBubble(for: userId, size: size)
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
            } else {
                initialsBubble(for: userId, size: size)
            }
        }
        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1))
    }

    @ViewBuilder
    private func initialsBubble(for userId: String, size: CGFloat) -> some View {
        let profile = dataStore.profilesMap[userId]
        let letter = String((profile?.fullName?.first ?? "?")).uppercased()
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color.accent.opacity(0.45), Color.accent.opacity(0.25)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Text(letter)
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
            }
    }

    /// Verbal companion under the name — "вложил больше доли" / "должен
    /// доплатить" / "всё ровно". Kept concise; amounts live on the right.
    private func deltaCaption(for b: SettlementCalculator.MemberBalance) -> String {
        if b.delta > 0 { return String(localized: "settlement.balance.positive") }
        if b.delta < 0 { return String(localized: "settlement.balance.negative") }
        return String(localized: "settlement.balance.even")
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
