import SwiftUI

/// Compact card for a single `SavingsChallenge`, used in the list view.
struct ChallengeCardView: View {
    let challenge: SavingsChallenge
    @Environment(AppViewModel.self) private var appViewModel

    private var cm: CurrencyManager { appViewModel.currencyManager }

    private var status: ChallengeStatus { challenge.status }
    private var fraction: Double { challenge.successFraction }

    private var progressLabel: String {
        switch challenge.type {
        case .noCafe:
            if challenge.progressAmount == 0 {
                return String(localized: "challenge.progress.clean")
            }
            return String(format: String(localized: "challenge.progress.spent"),
                          cm.formatAmount(challenge.progressAmount.displayAmount))
        case .categoryLimit:
            let spent = cm.formatAmount(challenge.progressAmount.displayAmount)
            let limit = cm.formatAmount((challenge.targetAmount ?? 0).displayAmount)
            return "\(spent) / \(limit)"
        case .weeklyAmount, .roundUp:
            let saved = cm.formatAmount(challenge.progressAmount.displayAmount)
            if let target = challenge.targetAmount {
                let targetStr = cm.formatAmount(target.displayAmount)
                return "\(saved) / \(targetStr)"
            }
            return saved
        }
    }

    private var statusColor: Color {
        switch status {
        case .active:
            return Color.accent
        case .completed:
            return Color.income
        case .abandoned:
            return Color.secondary
        }
    }

    /// A list row (the inset-grouped `List` provides the background).
    var body: some View {
        HStack(spacing: 14) {
            Text(challenge.type.icon)
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(statusColor.opacity(0.15), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(challenge.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if status == .completed {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.income)
                    }
                }

                Text(progressLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                ProgressView(value: min(max(fraction, 0), 1))
                    .tint(statusColor)
            }

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(challenge.daysRemaining)")
                    .font(.headline.monospacedDigit())
                Text(String(localized: "challenge.daysLeft"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .opacity(status == .active ? 1 : 0.4)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .opacity(status == .abandoned ? 0.5 : 1.0)
        .accessibilityElement(children: .combine)
    }
}
