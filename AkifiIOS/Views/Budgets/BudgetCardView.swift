import SwiftUI

struct BudgetCardView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let budget: Budget
    let metrics: BudgetMetrics
    let categories: [Category]

    private var progressColor: Color { Color(hex: metrics.progressColor) }

    private var categoryNames: String {
        guard let catIds = budget.categories, !catIds.isEmpty else {
            return "Все категории"
        }
        let names = categories.filter { catIds.contains($0.id) }.map(\.name)
        return names.isEmpty ? "Все категории" : names.joined(separator: ", ")
    }

    private var categoryIcons: String {
        guard let catIds = budget.categories, !catIds.isEmpty else { return "📊" }
        return categories.filter { catIds.contains($0.id) }.map(\.icon).prefix(3).joined()
    }

    private var statusLabel: (text: String, color: Color) {
        switch metrics.status {
        case .onTrack: return ("В норме", .green)
        case .warning: return ("Внимание", Color(hex: "#F59E0B"))
        case .nearLimit: return ("Почти лимит", .orange)
        case .overLimit: return ("Превышен", .red)
        }
    }

    private var riskBorderColor: Color {
        switch metrics.riskLevel {
        case .low: return .clear
        case .medium: return Color(hex: "#F59E0B").opacity(0.3)
        case .high: return .orange.opacity(0.4)
        case .critical: return .red.opacity(0.4)
        }
    }

    private var paceText: (text: String, color: Color) {
        if metrics.paceRatio <= 1.0 {
            return ("В темпе", .green)
        } else {
            let overage = Int((metrics.paceRatio - 1.0) * 100)
            return ("+\(overage)%", Color(hex: "#F59E0B"))
        }
    }

    private var fmt: CurrencyManager { appViewModel.currencyManager }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: icons + name + status badge + period
            HStack {
                Text(categoryIcons)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(budget.name)
                        .font(.subheadline.weight(.semibold))
                    Text(categoryNames)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Status pill
                Text(statusLabel.text)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusLabel.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusLabel.color.opacity(0.12))
                    .clipShape(Capsule())
            }

            // Progress bar with threshold markers
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(.systemGray5))

                    RoundedRectangle(cornerRadius: 6)
                        .fill(progressColor.gradient)
                        .frame(width: geo.size.width * min(CGFloat(metrics.utilization) / 100, 1.0))

                    // 80% marker
                    Rectangle()
                        .fill(Color(.systemGray3))
                        .frame(width: 1.5)
                        .offset(x: geo.size.width * 0.8)

                    // 100% marker
                    if metrics.utilization < 100 {
                        Rectangle()
                            .fill(Color(.systemGray3))
                            .frame(width: 1.5)
                            .offset(x: geo.size.width - 1)
                    }
                }
            }
            .frame(height: 10)

            // Stats row: spent/limit + pace + utilization %
            HStack {
                Text("\(fmt.formatAmount(metrics.spent.displayAmount))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(progressColor)
                + Text(" из \(fmt.formatAmount(metrics.effectiveLimit.displayAmount))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                // Pace indicator
                Text(paceText.text)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(paceText.color)

                Text("\(metrics.utilization)%")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(progressColor)
            }

            // Safe-to-spend daily + remaining days
            if metrics.remainingDays > 0 && metrics.remaining > 0 {
                HStack(spacing: 16) {
                    Label {
                        Text("\(fmt.formatAmount(metrics.safeToSpendDaily.displayAmount))/день")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "shield.checkered")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    Label {
                        Text("\(metrics.remainingDays) дн. осталось")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "calendar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.secondary)
            } else if metrics.remaining <= 0 {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text("Бюджет превышен на \(fmt.formatAmount(abs(metrics.remaining).displayAmount))")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(riskBorderColor, lineWidth: riskBorderColor == .clear ? 0 : 1.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
    }
}
