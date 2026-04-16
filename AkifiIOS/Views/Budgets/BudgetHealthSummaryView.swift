import SwiftUI

struct BudgetHealthSummaryView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let budgets: [Budget]
    let allMetrics: [BudgetMetrics]

    private var totalLimit: Int64 { allMetrics.reduce(0) { $0 + $1.effectiveLimit } }
    private var totalSpent: Int64 { allMetrics.reduce(0) { $0 + $1.spent } }
    private var totalSubCommitted: Int64 { allMetrics.reduce(0) { $0 + $1.subscriptionCommitted } }
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
                HStack(spacing: 2) {
                    ForEach(Array(zip(budgets, allMetrics)), id: \.0.id) { budget, metrics in
                        let proportion = totalLimit > 0
                            ? CGFloat(metrics.effectiveLimit) / CGFloat(totalLimit)
                            : 1.0 / CGFloat(max(1, allMetrics.count))
                        let segmentWidth = max(4, (geo.size.width - CGFloat(max(0, allMetrics.count - 1)) * 2) * proportion)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(hex: metrics.progressColor).gradient)
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
