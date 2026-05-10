import SwiftUI
import Charts

/// Bar chart of incomes vs expenses bucketed within the user-selected
/// period. Buckets are sub-month (day / week) for short windows, so this
/// widget can't be served from `monthlyAggregates`. Instead it memoizes
/// the `[CashflowPoint]` computation locally and only reruns it when the
/// transaction set, account scope, or period actually change.
struct CashflowChartView: View {
    /// Raw inputs — kept here (instead of passing in `[CashflowPoint]`)
    /// so the cache lives close to the data it derives from.
    let transactions: [Transaction]
    let period: WidgetPeriod
    let dataStore: DataStore
    let viewModel: AnalyticsViewModel

    /// Cache fingerprint mirrors `AnalyticsTabState.CacheKey`. We rely on
    /// `txGenerationToken` (bumped by `DataStore.rebuildCaches()`) to catch
    /// FX-rate / amount changes that don't change `transactions.count`.
    private struct CacheKey: Equatable, Hashable {
        let txCount: Int
        let txGenerationToken: UInt64
        let accountId: String?
        let period: WidgetPeriod
    }

    @State private var cachedKey: CacheKey?
    @State private var cachedPoints: [CashflowPoint] = []

    private var currentKey: CacheKey {
        CacheKey(
            txCount: transactions.count,
            txGenerationToken: dataStore.txGenerationToken,
            accountId: viewModel.selectedAccountId,
            period: period
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "analytics.cashflow"))
                .font(.headline)

            if cachedPoints.isEmpty && cachedKey != nil {
                // Cache populated but yielded no buckets — same "no data"
                // branch as before.
                ContentUnavailableView(String(localized: "common.noData"), systemImage: "chart.bar")
                    .frame(height: 200)
            } else if cachedKey == nil {
                // First appearance, cache not yet primed. Render an empty
                // chart frame at full height so layout doesn't pop when
                // data lands one frame later via `.task(id:)`.
                Color.clear.frame(height: 220)
            } else {
                Chart(cachedPoints) { point in
                    BarMark(
                        x: .value(String(localized: "chart.period"), point.label),
                        y: .value(String(localized: "chart.amount"), point.income)
                    )
                    .foregroundStyle(.green.gradient)
                    .position(by: .value("type", String(localized: "common.incomes")))

                    BarMark(
                        x: .value(String(localized: "chart.period"), point.label),
                        y: .value(String(localized: "chart.amount"), point.expense)
                    )
                    .foregroundStyle(.red.gradient)
                    .position(by: .value("type", String(localized: "common.expenses")))
                }
                .chartForegroundStyleScale([
                    String(localized: "common.incomes"): Color.green,
                    String(localized: "common.expenses"): Color.red
                ])
                .frame(height: 220)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // `task(id:)` recomputes the bucket list once per key transition.
        // `cashflowData(...)` does N date-parses + bucketing per row, so
        // memoizing it here turns the previous "every redraw" hot path
        // into "only when inputs actually change".
        .task(id: currentKey) {
            let key = currentKey
            if cachedKey != key {
                cachedPoints = viewModel.cashflowData(from: transactions, dataStore: dataStore)
                cachedKey = key
            }
        }
    }
}
