import SwiftUI

struct PortfolioChartView: View {
    @Environment(AppViewModel.self) private var appViewModel

    /// IDs of accounts the user has chosen to exclude from the portfolio
    /// rollup. Stored as a comma-joined string in UserDefaults — `Set` /
    /// `Codable` aren't directly supported by `@AppStorage`, but the data
    /// here is small (handful of UUIDs), so a manual encode keeps things
    /// simple. The filter survives app restarts and follows the user
    /// across screens that show this card.
    private static let excludedKey = "portfolio.excludedAccountIds"

    @State private var excludedIds: Set<String> = Self.loadExcluded()

    private var dataStore: DataStore { appViewModel.dataStore }

    /// Every account the user owns, alphabetised — drives the filter menu.
    /// Sorting by name keeps the filter list stable as balances move.
    private var allAccountsSorted: [Account] {
        dataStore.accounts.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Accounts that contribute to the portfolio rollup. Excluded ones are
    /// removed up-front so every downstream metric (total, share %, list)
    /// stays in sync with the same filter view. Inline-computed: the work
    /// is O(accounts) and `dataStore.balance(for:)` is already cached
    /// O(1) — memoizing this in `@State` looked tempting in the perf
    /// audit, but writing to `@State` from `body` evaluation is a SwiftUI
    /// antipattern (the current frame reads the *previous* values). We
    /// keep the heavy lifting on the `DataStore` side via the balance
    /// cache and the `Layout`-based stacked bar instead.
    private var portfolioData: [(account: Account, balance: Decimal)] {
        dataStore.accounts
            .filter { !excludedIds.contains($0.id) }
            .map { account in
                (account: account, balance: dataStore.balance(for: account).displayAmount)
            }
            .sorted { $0.balance > $1.balance }
    }

    private var totalBalance: Decimal {
        portfolioData.reduce(.zero) { $0 + $1.balance }
    }

    private var totalPositive: Decimal {
        portfolioData.reduce(.zero) { $0 + max(0, $1.balance) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "analytics.portfolio"))
                    .font(.headline)
                Spacer()
                filterMenu
            }

            // Total balance with sign
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(formattedTotal)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(totalBalance < 0 ? Color.expense : .primary)
            }

            // Stacked progress bar — only positive balances.
            // We swapped a GeometryReader for a custom proportional Layout:
            // the old reader forced a re-layout pass on the parent every
            // time the card crossed the viewport, which showed up as jank
            // on long analytics scrolls. The Layout below splits the
            // available width by precomputed Double weights — no runtime
            // geometry lookup on the hot path.
            if totalPositive > 0 {
                let totalPositiveDouble = Double(truncating: totalPositive as NSDecimalNumber)
                let segments: [(id: String, color: String, weight: Double)] = portfolioData
                    .compactMap { item in
                        guard item.balance > 0 else { return nil }
                        let w = Double(truncating: item.balance as NSDecimalNumber) / totalPositiveDouble
                        return (item.account.id, item.account.color, w)
                    }

                ProportionalHStack(spacing: 1.5, weights: segments.map(\.weight), minSegmentWidth: 4) {
                    ForEach(segments, id: \.id) { seg in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(hex: seg.color).gradient)
                    }
                }
                .frame(height: 8)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            // Account list
            if !portfolioData.isEmpty {
                Divider()

                VStack(spacing: 0) {
                    ForEach(Array(portfolioData.enumerated()), id: \.element.account.id) { index, item in
                        accountRow(item: item)
                            .padding(.vertical, 10)

                        if index < portfolioData.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }

    // MARK: - Filter menu

    /// Account-include / exclude picker. Tap reveals every account; tapping
    /// a row toggles its inclusion. Excluded accounts don't contribute to
    /// the total or the stacked bar. The label shows a counter pip when
    /// the filter is active so users notice the rollup is partial.
    @ViewBuilder
    private var filterMenu: some View {
        Menu {
            if !excludedIds.isEmpty {
                Button {
                    excludedIds.removeAll()
                    saveExcluded()
                } label: {
                    Label(
                        String(localized: "portfolio.filter.reset"),
                        systemImage: "arrow.counterclockwise"
                    )
                }
                Divider()
            }
            // Header row inside the menu — anchors the user on what the
            // checkmarks mean. Without this it can read like "select one".
            Section(String(localized: "portfolio.filter.title")) {
                ForEach(allAccountsSorted, id: \.id) { acc in
                    Button {
                        toggle(acc.id)
                    } label: {
                        let included = !excludedIds.contains(acc.id)
                        if included {
                            Label("\(acc.icon) \(acc.name)", systemImage: "checkmark")
                        } else {
                            // SwiftUI Menu hides the icon slot when there's
                            // no systemImage — using "circle" keeps the row
                            // visually aligned with checked siblings.
                            Label("\(acc.icon) \(acc.name)", systemImage: "circle")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: excludedIds.isEmpty
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
                    .font(.subheadline)
                if excludedIds.isEmpty {
                    Text(String(localized: "analytics.allBalances"))
                        .font(.caption)
                } else {
                    Text(String(format: String(localized: "portfolio.filter.activeCounter %lld %lld"),
                                portfolioData.count,
                                allAccountsSorted.count))
                        .font(.caption.weight(.semibold))
                }
            }
            .foregroundStyle(excludedIds.isEmpty ? Color.secondary : Color.accent)
        }
        .accessibilityLabel(String(localized: "portfolio.filter.title"))
    }

    private func toggle(_ accountId: String) {
        if excludedIds.contains(accountId) {
            excludedIds.remove(accountId)
        } else {
            excludedIds.insert(accountId)
        }
        saveExcluded()
    }

    private static func loadExcluded() -> Set<String> {
        guard let raw = UserDefaults.standard.string(forKey: excludedKey),
              !raw.isEmpty else { return [] }
        return Set(raw.split(separator: ",").map(String.init))
    }

    private func saveExcluded() {
        if excludedIds.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.excludedKey)
        } else {
            UserDefaults.standard.set(
                excludedIds.sorted().joined(separator: ","),
                forKey: Self.excludedKey
            )
        }
    }

    // MARK: - Account row

    private func accountRow(item: (account: Account, balance: Decimal)) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(hex: item.account.color))
                .frame(width: 8, height: 8)

            Text(item.account.icon)
                .font(.title3)

            Text(item.account.name)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()

            // Balance with sign and color
            Text(formattedBalance(item.balance))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(item.balance < 0 ? Color.expense : .primary)

            // Percentage of total positive assets.
            // The displayed value is a whole-percent integer, so doing the
            // ratio in Double is safe (cents-of-cents precision loss can't
            // affect the printed figure) and meaningfully cheaper than
            // Decimal in the row hot path.
            if totalPositive > 0 {
                let balanceD = Double(truncating: item.balance as NSDecimalNumber)
                let totalD = Double(truncating: totalPositive as NSDecimalNumber)
                let pct = balanceD / totalD * 100
                Text(item.balance >= 0 ? "\(Int(pct))%" : "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

    // MARK: - Formatting

    private var formattedTotal: String {
        let cm = appViewModel.currencyManager
        let converted = cm.convert(abs(totalBalance))
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let formatted = formatter.string(from: converted as NSDecimalNumber) ?? "0"
        let sign = totalBalance < 0 ? "-" : ""
        return "\(sign)\(formatted) \(cm.selectedCurrency.symbol)"
    }

    private func formattedBalance(_ balance: Decimal) -> String {
        let cm = appViewModel.currencyManager
        if balance < 0 {
            return "-\(cm.formatAmount(abs(balance)))"
        }
        return cm.formatAmount(balance)
    }
}

// MARK: - ProportionalHStack

/// A horizontal `Layout` that distributes the available width across its
/// subviews proportionally to a pre-computed weight vector. Replaces the
/// previous `GeometryReader { geo in ... geo.size.width * pct }` pattern
/// in the portfolio stacked bar: the reader caused a re-layout of the
/// enclosing `VStack` whenever the card's frame changed during scroll,
/// which is the workload this view sits in. By moving the proportional
/// math into a `Layout`, the parent treats this view as opaque and never
/// has to read geometry on the scroll path.
///
/// `weights` must match the subview count in order. A `minSegmentWidth`
/// floor keeps tiny slivers visible even when their share rounds to ~0.
private struct ProportionalHStack: Layout {
    let spacing: CGFloat
    let weights: [Double]
    let minSegmentWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let height = proposal.height ?? 8
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let count = subviews.count
        let totalSpacing = spacing * CGFloat(max(0, count - 1))
        let usable = max(0, bounds.width - totalSpacing)

        // Normalize the weights — callers may hand us a vector that
        // doesn't sum to 1.0 if a segment was filtered out upstream.
        let weightSum = weights.prefix(count).reduce(0, +)
        let safeSum = weightSum > 0 ? weightSum : Double(count)

        var x = bounds.minX
        for (i, sub) in subviews.enumerated() {
            let w: Double = i < weights.count ? weights[i] : (1.0 / Double(count))
            let raw = CGFloat(w / safeSum) * usable
            let segWidth = max(minSegmentWidth, raw)
            sub.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: segWidth, height: bounds.height)
            )
            x += segWidth + spacing
        }
    }
}
