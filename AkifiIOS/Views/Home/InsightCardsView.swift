import SwiftUI

struct InsightCardsView: View {
    @Environment(AppViewModel.self) private var appViewModel

    private var dataStore: DataStore { appViewModel.dataStore }

    private var insights: [InsightEngine.Insight] {
        let fmt = appViewModel.currencyManager
        return InsightEngine.generate(
            InsightEngine.Input(
                transactions: dataStore.transactions,
                categories: dataStore.categories,
                budgets: dataStore.budgets,
                subscriptions: dataStore.subscriptions,
                formatAmount: { amount in fmt.formatAmount(amount.displayAmount) }
            )
        )
    }

    var body: some View {
        if !insights.isEmpty {
            VStack(spacing: 8) {
                ForEach(insights) { insight in
                    InsightCardView(insight: insight)
                }
            }
        }
    }
}

struct InsightCardView: View {
    let insight: InsightEngine.Insight

    var body: some View {
        HStack(spacing: 12) {
            Text(insight.emoji)
                .font(.title2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(insight.title)
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(insight.kind.color.opacity(0.6))
                }
                Text(insight.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(insight.kind.color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [insight.kind.color.opacity(0.5), insight.kind.color.opacity(0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }
}
