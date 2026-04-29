import Foundation
import Observation

/// Observable facade over the net-worth feature. Owns the three collections
/// (assets, liabilities, snapshots), the current `Breakdown`, and the
/// CRUD + snapshot-capture operations exposed to the UI.
///
/// Created once by `NetWorthDashboardView` (via `@State`) — any sub-view
/// that needs CRUD should call methods on this VM, not directly on the
/// repos, so the local arrays stay in sync without a full reload.
@MainActor
@Observable
final class NetWorthViewModel {
    var assets: [Asset] = []
    var liabilities: [Liability] = []
    var snapshots: [NetWorthSnapshot] = []
    var breakdown: NetWorthCalculator.Breakdown?

    var isLoading = false
    var errorMessage: String?

    private let assetRepo = AssetRepository()
    private let liabilityRepo = LiabilityRepository()
    private let snapshotRepo = NetWorthSnapshotRepository()

    /// Fetches assets + liabilities + snapshots in parallel, recomputes
    /// the breakdown, and (if today's snapshot is missing) automatically
    /// captures it. Failures are non-fatal — the VM surfaces the last
    /// error via `errorMessage` but keeps whatever partial state loaded.
    func load(dataStore: DataStore, currencyManager: CurrencyManager) async {
        isLoading = true
        errorMessage = nil

        async let assetsFetch = assetRepo.fetchAll()
        async let liabilitiesFetch = liabilityRepo.fetchAll()
        async let snapshotsFetch = snapshotRepo.fetchForUser(limit: 365)

        do { assets = try await assetsFetch }
        catch { errorMessage = error.localizedDescription; AppLogger.data.warning("assets: \(error.localizedDescription)") }

        do { liabilities = try await liabilitiesFetch }
        catch { errorMessage = error.localizedDescription; AppLogger.data.warning("liabilities: \(error.localizedDescription)") }

        do { snapshots = try await snapshotsFetch }
        catch { errorMessage = error.localizedDescription; AppLogger.data.warning("snapshots: \(error.localizedDescription)") }

        // Recompute breakdown locally — always in the user's base currency
        // (dataCurrency), not the display currency, so stored snapshots
        // remain consistent even if the user toggles display currencies.
        recomputeBreakdown(dataStore: dataStore, currencyManager: currencyManager)

        // Auto-capture today's snapshot if we don't have one yet. Skipped
        // silently on failure so a broken write doesn't block the dashboard.
        let today = NetWorthSnapshotRepository.dateFormatter.string(from: Date())
        let alreadyCapturedToday = snapshots.contains { $0.snapshotDate == today }
        if !alreadyCapturedToday, let breakdown {
            let base = currencyManager.dataCurrency.rawValue
            do {
                let snap = try await snapshotRepo.upsertToday(
                    accountsTotal: breakdown.accountsTotal,
                    assetsTotal: breakdown.assetsTotal,
                    liabilitiesTotal: breakdown.liabilitiesTotal,
                    netWorth: breakdown.netWorth,
                    currency: base
                )
                // Prepend the new snapshot so the chart picks it up without a refetch.
                snapshots.insert(snap, at: 0)
            } catch {
                AppLogger.data.warning("snapshot upsert failed: \(error.localizedDescription)")
            }
        }

        isLoading = false
    }

    /// Manually capture a fresh snapshot (used by a future "refresh" button
    /// + triggered on significant changes). Idempotent — overwrites today's
    /// existing row if present.
    func captureSnapshot(dataStore: DataStore, currencyManager: CurrencyManager) async {
        recomputeBreakdown(dataStore: dataStore, currencyManager: currencyManager)
        guard let breakdown else { return }
        let base = currencyManager.dataCurrency.rawValue
        do {
            let snap = try await snapshotRepo.upsertToday(
                accountsTotal: breakdown.accountsTotal,
                assetsTotal: breakdown.assetsTotal,
                liabilitiesTotal: breakdown.liabilitiesTotal,
                netWorth: breakdown.netWorth,
                currency: base
            )
            // Replace today's row if it already existed, else prepend.
            if let idx = snapshots.firstIndex(where: { $0.snapshotDate == snap.snapshotDate }) {
                snapshots[idx] = snap
            } else {
                snapshots.insert(snap, at: 0)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Asset CRUD

    /// CRUD methods are `throws` so the calling form (AssetFormView) can
    /// catch a backend reject — RLS, FK failures, NOT NULL violations —
    /// and show the message in an alert instead of dismissing silently.
    /// A successful path still publishes through `assets` / `breakdown`
    /// for the dashboard to react.
    func createAsset(_ input: CreateAssetInput,
                     dataStore: DataStore,
                     currencyManager: CurrencyManager) async throws {
        let asset = try await assetRepo.create(input)
        assets.insert(asset, at: 0)
        recomputeBreakdown(dataStore: dataStore, currencyManager: currencyManager)
    }

    func updateAsset(id: String, _ input: UpdateAssetInput,
                     dataStore: DataStore,
                     currencyManager: CurrencyManager) async throws {
        try await assetRepo.update(id: id, input)
        // Refetch that one row — simpler than reconstructing locally
        // given PATCH requests don't echo the full row.
        assets = try await assetRepo.fetchAll()
        recomputeBreakdown(dataStore: dataStore, currencyManager: currencyManager)
    }

    func deleteAsset(id: String,
                     dataStore: DataStore,
                     currencyManager: CurrencyManager) async throws {
        try await assetRepo.delete(id: id)
        assets.removeAll { $0.id == id }
        recomputeBreakdown(dataStore: dataStore, currencyManager: currencyManager)
    }

    // MARK: - Liability CRUD

    func createLiability(_ input: CreateLiabilityInput,
                         dataStore: DataStore,
                         currencyManager: CurrencyManager) async {
        do {
            let liab = try await liabilityRepo.create(input)
            liabilities.insert(liab, at: 0)
            recomputeBreakdown(dataStore: dataStore, currencyManager: currencyManager)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateLiability(id: String, _ input: UpdateLiabilityInput,
                         dataStore: DataStore,
                         currencyManager: CurrencyManager) async {
        do {
            try await liabilityRepo.update(id: id, input)
            liabilities = try await liabilityRepo.fetchAll()
            recomputeBreakdown(dataStore: dataStore, currencyManager: currencyManager)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteLiability(id: String,
                         dataStore: DataStore,
                         currencyManager: CurrencyManager) async {
        do {
            try await liabilityRepo.delete(id: id)
            liabilities.removeAll { $0.id == id }
            recomputeBreakdown(dataStore: dataStore, currencyManager: currencyManager)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Private helpers

    /// Rebuilds `breakdown` from the current `assets`, `liabilities`, and
    /// account balances in `dataStore`. Called after every mutation so
    /// the dashboard re-renders without a network round-trip.
    private func recomputeBreakdown(dataStore: DataStore, currencyManager: CurrencyManager) {
        // `dataStore.balance(for:)` already returns the balance normalized
        // into base currency (see DataStore.rebuildCaches). Pass the base
        // currency as the "from" side so the calculator's per-account FX
        // step becomes a no-op and doesn't double-convert.
        let baseCode = currencyManager.dataCurrency.rawValue
        let accountBalances: [(accountCurrency: String, amount: Int64)] = dataStore.accounts.map {
            (baseCode, dataStore.balance(for: $0))
        }

        // CurrencyManager.rates uses Double for historical reasons; convert
        // to Decimal at the boundary so the calculator stays precision-safe.
        let rates: [String: Decimal] = currencyManager.rates.reduce(into: [:]) { acc, pair in
            acc[pair.key] = Decimal(pair.value)
        }

        breakdown = NetWorthCalculator.compute(
            accountBalances: accountBalances,
            assets: assets,
            liabilities: liabilities,
            fxRates: rates,
            baseCurrency: currencyManager.dataCurrency
        )
    }
}
