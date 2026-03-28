import SwiftUI

struct SavingsGoalCardView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let goal: SavingsGoal
    let progress: Double
    let daysRemaining: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(goal.icon)
                    .font(.title2)
                    .frame(width: 40, height: 40)
                    .background(Color(hex: goal.color).opacity(0.15))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(goal.name)
                        .font(.headline)
                    if let days = daysRemaining {
                        Text(days > 0 ? String(localized: "budget.daysRemaining.\(days)") : String(localized: "savings.expired"))
                            .font(.caption)
                            .foregroundStyle(days > 0 ? Color.secondary : Color.red)
                    }
                }
                Spacer()

                if goal.status == .completed {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.title2)
                }
            }

            // Progress ring + amounts
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(.quaternary, lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color(hex: goal.color).gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(progress * 100))%")
                        .font(.caption2.weight(.bold))
                }
                .frame(width: 50, height: 50)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(appViewModel.currencyManager.formatAmount(goal.currentAmount.displayAmount))
                            .font(.subheadline.weight(.semibold))
                        Text(String(localized: "common.of"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(appViewModel.currencyManager.formatAmount(goal.targetAmount.displayAmount))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.quaternary)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(hex: goal.color).gradient)
                                .frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 6)
                }
            }
        }
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
