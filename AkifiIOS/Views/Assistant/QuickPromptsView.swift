import SwiftUI

struct QuickPromptsView: View {
    let onSelect: (String) -> Void
    var dataStore: DataStore?

    private var prompts: [(icon: String, display: String, query: String)] {
        var result: [(String, String, String)] = []

        // Dynamic: per-account spending prompt if user has multiple accounts
        if let ds = dataStore, ds.accounts.count > 1 {
            if let primary = ds.accounts.first(where: { $0.isPrimary }) ?? ds.accounts.first {
                result.append((
                    "creditcard",
                    String(localized: "assistant.prompt.accountSpending \(primary.name)"),
                    String(localized: "assistant.prompt.accountSpending.query \(primary.name)")
                ))
            }
        }

        // Dynamic: top expense category analysis
        if let ds = dataStore {
            let expenseCategories = ds.categories.filter { $0.type == .expense }
            // Find the category with the highest total expense
            var categoryTotals: [String: Int64] = [:]
            for tx in ds.transactions where tx.type == .expense {
                if let catId = tx.categoryId {
                    categoryTotals[catId, default: 0] += tx.amount
                }
            }
            if let topCatId = categoryTotals.max(by: { $0.value < $1.value })?.key,
               let topCat = expenseCategories.first(where: { $0.id == topCatId }) {
                result.append((
                    "magnifyingglass.circle",
                    String(localized: "assistant.prompt.analyzeCategory \(topCat.icon) \(topCat.name)"),
                    String(localized: "assistant.prompt.analyzeCategory.query \(topCat.name)")
                ))
            }
        }

        // Static fallback prompts
        result.append(contentsOf: [
            ("chart.bar", String(localized: "assistant.prompt.spending"), String(localized: "assistant.prompt.spending.query")),
            ("list.bullet", String(localized: "assistant.prompt.categories"), String(localized: "assistant.prompt.categories.query")),
            ("arrow.up.arrow.down", String(localized: "assistant.prompt.compare"), String(localized: "assistant.prompt.compare.query")),
            ("lightbulb", String(localized: "assistant.prompt.save"), String(localized: "assistant.prompt.save.query")),
            ("exclamationmark.triangle", String(localized: "assistant.prompt.anomalies"), String(localized: "assistant.prompt.anomalies.query")),
            ("wallet.bifold", String(localized: "assistant.prompt.budget"), String(localized: "assistant.prompt.budget.query")),
        ])

        // Limit to 6 total prompts
        return Array(result.prefix(6))
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(prompts, id: \.query) { icon, display, query in
                Button {
                    onSelect(query)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: icon)
                            .font(.subheadline)
                            .foregroundStyle(Color.accent)
                            .frame(width: 24)
                        Text(display)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.06), radius: 2, x: 0, y: 1)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
    }
}
