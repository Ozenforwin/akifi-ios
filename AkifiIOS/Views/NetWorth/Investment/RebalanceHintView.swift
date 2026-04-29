import SwiftUI

/// Shows the `PortfolioCalculator.rebalance` no-sell action list with
/// labels users can read at a glance: "Buy USD 1,200 of US-stock —
/// drift +12%". When the user has no target set yet, prompts them to
/// open `TargetAllocationView`.
///
/// Owned by `PortfolioDashboardView` via the same `PortfolioViewModel`
/// so summary, target and actions stay consistent.
struct RebalanceHintView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: PortfolioViewModel
    @Environment(AppViewModel.self) private var appViewModel

    @State private var showingTargetEditor = false

    private var cm: CurrencyManager { appViewModel.currencyManager }

    private var actions: [PortfolioCalculator.RebalanceAction] {
        guard let target = viewModel.targetAllocation,
              let summary = viewModel.summary else { return [] }
        return PortfolioCalculator.rebalance(summary: summary, target: target)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if viewModel.targetAllocation == nil {
                        emptyState
                    } else if actions.isEmpty {
                        onTargetState
                    } else {
                        actionsList
                    }
                    targetSummary
                }
                .padding(16)
            }
            .navigationTitle(String(localized: "rebalance.hint.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "common.done")) { dismiss() }
                }
            }
            .sheet(isPresented: $showingTargetEditor) {
                TargetAllocationView(viewModel: viewModel)
                    .presentationBackground(.ultraThinMaterial)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "scope")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(String(localized: "rebalance.empty.title"))
                .font(.headline)
            Text(String(localized: "rebalance.empty.subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showingTargetEditor = true
            } label: {
                Label(String(localized: "rebalance.empty.cta"),
                      systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    @ViewBuilder
    private var onTargetState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)
            Text(String(localized: "rebalance.onTarget.title"))
                .font(.headline)
            Text(String(localized: "rebalance.onTarget.subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    @ViewBuilder
    private var actionsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "rebalance.actions.title"))
                    .font(.headline)
                Spacer()
                Text(String(format: String(localized: "rebalance.totalBuyFormat"),
                            cm.formatAmount(totalBuy.displayAmount)))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.accent)
            }
            VStack(spacing: 0) {
                ForEach(Array(actions.enumerated()), id: \.offset) { idx, action in
                    actionRow(action)
                    if idx < actions.count - 1 {
                        Divider().padding(.leading, 56)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }

    private var totalBuy: Int64 {
        actions.reduce(0) { $0 + $1.buyAmountMinor }
    }

    @ViewBuilder
    private func actionRow(_ action: PortfolioCalculator.RebalanceAction) -> some View {
        HStack(spacing: 12) {
            Image(systemName: action.kind.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color(hex: action.kind.defaultHex))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(action.kind.localizedTitle)
                    .font(.subheadline.weight(.semibold))
                Text(driftLabel(action))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("+\(cm.formatAmount(action.buyAmountMinor.displayAmount))")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func driftLabel(_ action: PortfolioCalculator.RebalanceAction) -> String {
        let curPct = NSDecimalNumber(decimal: action.currentWeight * 100).doubleValue
        let targetPct = NSDecimalNumber(decimal: action.targetWeight * 100).doubleValue
        return String(format: String(localized: "rebalance.driftFormat"),
                      curPct, targetPct)
    }

    @ViewBuilder
    private var targetSummary: some View {
        Button {
            showingTargetEditor = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accent)
                Text(String(localized: "rebalance.editTarget"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
    }
}
