import SwiftUI

struct BudgetHealthSummaryView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let budgets: [Budget]
    let allMetrics: [BudgetMetrics]

    private var ctx: BudgetMath.CurrencyContext { appViewModel.dataStore.currencyContext }

    /// Each budget's metrics are denominated in that budget's own currency —
    /// convert to base before summing, or a 4 000 000 VND limit gets added
    /// to RUB kopecks as-is and the header total explodes.
    private var baseLimits: [Int64] {
        zip(budgets, allMetrics).map { BudgetMath.amountInBase($1.effectiveLimit, budget: $0, currencyContext: ctx) }
    }
    private var totalLimit: Int64 { baseLimits.reduce(0, +) }
    private var totalSpent: Int64 {
        zip(budgets, allMetrics).map { BudgetMath.amountInBase($1.spent, budget: $0, currencyContext: ctx) }.reduce(0, +)
    }
    private var totalSubCommitted: Int64 {
        zip(budgets, allMetrics).map { BudgetMath.amountInBase($1.subscriptionCommitted, budget: $0, currencyContext: ctx) }.reduce(0, +)
    }
    private var overallUtilization: Int {
        guard totalLimit > 0 else { return 0 }
        return min(999, Int(Double(totalSpent) / Double(totalLimit) * 100))
    }
    private var onTrackCount: Int { allMetrics.filter { $0.status == .onTrack }.count }
    private var warningCount: Int { allMetrics.filter { $0.status == .warning || $0.status == .nearLimit }.count }
    private var overCount: Int { allMetrics.filter { $0.status == .overLimit }.count }

    private var fmt: CurrencyManager { appViewModel.currencyManager }

    private var overallColor: Color {
        if overallUtilization >= 100 { return .red }
        if overallUtilization >= 75 { return .orange }
        return .green
    }

    var body: some View {
        VStack(spacing: 12) {
            // Top row: totals
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "budget.summary.total"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(fmt.formatAmount(totalSpent.displayAmount))
                        .font(.title3.weight(.bold).monospacedDigit())
                    + Text(" / \(fmt.formatAmount(totalLimit.displayAmount))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(overallUtilization)%")
                    .font(.title2.weight(.bold).monospacedDigit())
                    .foregroundStyle(overallColor)
            }

            // Segmented progress bar
            GeometryReader { geo in
                let limits = baseLimits
                HStack(spacing: 2) {
                    ForEach(Array(zip(budgets, allMetrics).enumerated()), id: \.element.0.id) { index, pair in
                        let proportion = totalLimit > 0
                            ? CGFloat(limits[index]) / CGFloat(totalLimit)
                            : 1.0 / CGFloat(max(1, allMetrics.count))
                        let segmentWidth = max(4, (geo.size.width - CGFloat(max(0, allMetrics.count - 1)) * 2) * proportion)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(hex: pair.1.progressColor).gradient)
                            .frame(width: segmentWidth)
                    }
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())

            // Status counters
            HStack(spacing: 16) {
                if onTrackCount > 0 {
                    statusCounter(count: onTrackCount, icon: "checkmark.circle.fill", color: .green, label: String(localized: "budget.status.onTrack"))
                }
                if warningCount > 0 {
                    statusCounter(count: warningCount, icon: "exclamationmark.triangle.fill", color: .orange, label: String(localized: "budget.status.warning"))
                }
                if overCount > 0 {
                    statusCounter(count: overCount, icon: "xmark.octagon.fill", color: .red, label: String(localized: "budget.status.overLimit"))
                }
                Spacer()
            }

            // Subscription commitment summary
            if totalSubCommitted > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "repeat.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.budget)
                    Text(String(localized: "budget.summary.subscriptions.\(fmt.formatAmount(totalSubCommitted.displayAmount))"))
                        .font(.caption)
                        .foregroundStyle(.primary)
                    if totalLimit > 0 {
                        let pct = Int(Double(totalSubCommitted) / Double(totalLimit) * 100)
                        Text("(\(pct)%)")
                            .font(.caption)
                            .foregroundStyle(pct > 50 ? Color.warning : .secondary)
                    }
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "budget.summary.accessibility.\(onTrackCount).\(warningCount).\(overCount).\(overallUtilization)"))
    }

    private func statusCounter(count: Int, icon: String, color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            Text("\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
