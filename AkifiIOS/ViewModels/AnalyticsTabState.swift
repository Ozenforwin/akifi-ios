import Foundation
import SwiftUI

/// View-state for `AnalyticsTabView` — owns the tab's period / account
/// filters and memoizes the two derived transaction projections that
/// every analytics widget consumes.
///
/// Memoization contract:
///  - `scopedTransactions` — `dataStore.transactions` filtered by
///    `selectedAccountId` only (period-independent).
///  - `periodTransactions` — scoped + clipped to `selectedPeriod`.
///
/// Both are recomputed lazily on access and cached behind a `CacheKey` that
/// fingerprints (`txCount`, `txGenerationToken`, `accountId`, `period`).
/// `txGenerationToken` is bumped by `DataStore.rebuildCaches()` and FX
/// updates, so any data-shape change invalidates without explicit
/// notifications.
///
/// `dataStore` is held `unowned` — `AnalyticsTabState` lives strictly inside
/// `AnalyticsTabView`, whose enclosing app keeps `DataStore` alive for the
/// process. This avoids both the retain cycle and the weak-unwrap noise.
@Observable @MainActor
final class AnalyticsTabState {
    var selectedPeriod: WidgetPeriod = .month
    var selectedAccountId: String?

    @ObservationIgnored unowned let dataStore: DataStore

    // MARK: - Cache

    private struct CacheKey: Equatable {
        let txCount: Int
        let txGenerationToken: UInt64
        let accountId: String?
        let period: WidgetPeriod
    }

    @ObservationIgnored private var cachedScopedKey: CacheKey?
    @ObservationIgnored private var cachedScoped: [Transaction]?
    @ObservationIgnored private var cachedPeriodKey: CacheKey?
    @ObservationIgnored private var cachedPeriod: [Transaction]?

    init(dataStore: DataStore) {
        self.dataStore = dataStore
    }

    // MARK: - Projections

    /// Transactions filtered by `selectedAccountId` (no period filter).
    /// Returns the full set when no account is selected. Stable across
    /// period changes — recomputes only when txns or account-id change.
    var scopedTransactions: [Transaction] {
        let key = CacheKey(
            txCount: dataStore.transactions.count,
            txGenerationToken: dataStore.txGenerationToken,
            accountId: selectedAccountId,
            period: .month  // period not part of scope identity; use a constant
        )
        if cachedScopedKey == key, let cached = cachedScoped {
            return cached
        }
        let result: [Transaction]
        if let accountId = selectedAccountId {
            result = dataStore.transactions.filter { $0.accountId == accountId }
        } else {
            result = dataStore.transactions
        }
        cachedScopedKey = key
        cachedScoped = result
        return result
    }

    /// `scopedTransactions` clipped to `selectedPeriod`. Recomputes when any
    /// of (tx data, account, period) changes.
    var periodTransactions: [Transaction] {
        let key = CacheKey(
            txCount: dataStore.transactions.count,
            txGenerationToken: dataStore.txGenerationToken,
            accountId: selectedAccountId,
            period: selectedPeriod
        )
        if cachedPeriodKey == key, let cached = cachedPeriod {
            return cached
        }
        let startDate = selectedPeriod.startDate()
        let df = AppDateFormatters.isoDate
        let scoped = scopedTransactions
        let result = scoped.filter { tx in
            guard let date = df.date(from: tx.date) else { return false }
            return date >= startDate
        }
        cachedPeriodKey = key
        cachedPeriod = result
        return result
    }
}
