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

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 48, height: 48)
                Text(challenge.type.icon).font(.title3)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(challenge.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if status == .completed {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(Color.income)
                    }
                }

                Text(progressLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(.systemGray5))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(statusColor)
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 6)
            }

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(challenge.daysRemaining)")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                Text(String(localized: "challenge.daysLeft"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .opacity(status == .active ? 1 : 0.4)
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(status == .abandoned ? 0.5 : 1.0)
    }
}
