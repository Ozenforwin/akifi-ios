import SwiftUI

/// One savings goal as a list row: icon, name, deadline, progress ring
/// and amounts. Lives inside an inset-grouped `List` — the row supplies
/// the background, so the view itself has none (content, not a card).
struct SavingsGoalCardView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let goal: SavingsGoal
    let progress: Double
    let daysRemaining: Int?

    @ScaledMetric(relativeTo: .body) private var ringSize: CGFloat = 44

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color(hex: goal.color).opacity(0.2), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color(hex: goal.color), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(goal.icon)
                    .font(.title3)
            }
            .frame(width: ringSize, height: ringSize)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(goal.name)
                        .font(.headline)
                        .lineLimit(1)
                    if goal.status == .completed {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(Color.income)
                            .accessibilityLabel(String(localized: "savings.completed"))
                    }
                }

                Text(String(localized: "savings.detail.ofTarget \(appViewModel.currencyManager.formatAmount(goal.targetAmount.displayAmount))"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                if let days = daysRemaining {
                    Text(days > 0 ? String(localized: "budget.daysRemaining.\(days)") : String(localized: "savings.expired"))
                        .font(.footnote)
                        .foregroundStyle(days > 0 ? Color.secondary : Color.expense)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(appViewModel.currencyManager.formatAmount(goal.currentAmount.displayAmount))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                Text(verbatim: "\(Int(progress * 100))%")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
