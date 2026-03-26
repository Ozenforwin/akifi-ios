import SwiftUI

struct BudgetCardView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let budget: Budget
    let spent: Int64
    let progress: Double
    let remaining: Int64
    let periodLabel: String
    let categories: [Category]

    private var progressColor: Color {
        if progress >= 1.0 { return .red }
        if progress >= (budget.alertThreshold ?? 0.8) { return .orange }
        return .green
    }

    private var categoryNames: String {
        guard let catIds = budget.categories, !catIds.isEmpty else {
            return "Все категории"
        }
        let names = categories
            .filter { catIds.contains($0.id) }
            .map(\.name)
        return names.isEmpty ? "Все категории" : names.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(budget.name)
                        .font(.headline)
                    Text(categoryNames)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(periodLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.systemBackground))
                    .clipShape(Capsule())
            }

            // Progress bar
            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.quaternary)
                        RoundedRectangle(cornerRadius: 6)
                            .fill(progressColor.gradient)
                            .frame(width: geo.size.width * min(progress, 1.0))
                    }
                }
                .frame(height: 10)

                HStack {
                    Text(appViewModel.currencyManager.formatAmount(spent.displayAmount))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(progressColor)
                    Text("из")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(appViewModel.currencyManager.formatAmount(budget.amount.displayAmount))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(progressColor)
                }
            }

            // Remaining
            if remaining > 0 {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.green)
                    Text("Осталось: \(appViewModel.currencyManager.formatAmount(remaining.displayAmount))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("Бюджет превышен на \(appViewModel.currencyManager.formatAmount(abs(remaining).displayAmount))")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
    }
}
