import Foundation
import Observation

/// Observable facade over the investment-portfolio surface. Owns the
/// list of holdings (across every Asset of category investment/crypto),
/// the cached `PortfolioCalculator.Summary`, and the CRUD operations
/// the UI calls into.
///
/// `NetWorthViewModel` already owns `assets` for the dashboard.
/// Portfolio screens get their own VM so the holdings load doesn't
/// add a second hit when the user only opens Net Worth, and so the
/// portfolio surface remains independent of how Assets are fetched
/// elsewhere. Both VMs read FX rates from `CurrencyManager`, so the
/// numbers stay consistent.
///
/// CRUD note: the DB trigger
/// `recompute_asset_value_on_holding_change` keeps `assets.current_value`
/// in sync after every insert/update/delete. Each mutation here
/// re-fetches both holdings and assets so the dashboard hero, pie
/// chart and per-asset rows pick up the new aggregate without a
/// round-trip through the user's pull-to-refresh.
@MainActor
@Observable
final class PortfolioViewModel {
    /// All `investment_holdings` rows for the current user, newest-first.
    var holdings: [InvestmentHolding] = []
    /// Assets of category `.investment` or `.crypto` only — the parents
    /// holdings can attach to. Cached here so the form's "parent asset"
    /// picker doesn't re-fetch on each open.
    var assetsForPortfolio: [Asset] = []
    /// Aggregate summary in the user's base currency. Recomputed locally
    /// after any mutation, no extra network call.
    var summary: PortfolioCalculator.Summary?

    var isLoading = false
    var errorMessage: String?

    private let holdingRepo = InvestmentHoldingRepository()
    private let assetRepo = AssetRepository()

    /// Fetch holdings + parent assets in parallel and recompute the
    /// summary. Failures are non-fatal — partial state is kept and the
    /// last error surfaces via `errorMessage` so the dashboard can show
    /// a banner without blanking out.
    func load(currencyManager: CurrencyManager) async {
        isLoading = true
        errorMessage = nil

        async let holdingsFetch = holdingRepo.fetchAll()
        async let assetsFetch = assetRepo.fetchAll()

        do { holdings = try await holdingsFetch }
        catch { errorMessage = error.localizedDescription; AppLogger.data.warning("holdings: \(error.localizedDescription)") }

        do {
            let all = try await assetsFetch
            assetsForPortfolio = all.filter { $0.category == .investment || $0.category == .crypto }
        } catch {
            errorMessage = error.localizedDescription
            AppLogger.data.warning("assets-for-portfolio: \(error.localizedDescription)")
        }

        recomputeSummary(currencyManager: currencyManager)
        isLoading = false
    }

    // MARK: - CRUD

    /// Create a new holding. The DB trigger updates the parent
    /// `Asset.current_value` server-side; we refetch assets afterwards
    /// to surface the new value in the UI without waiting for the next
    /// dashboard refresh.
    func create(_ input: CreateHoldingInput,
                currencyManager: CurrencyManager) async {
        do {
            let created = try await holdingRepo.create(input)
            holdings.insert(created, at: 0)
            await refreshParentAsset(id: created.assetId)
            recomputeSummary(currencyManager: currencyManager)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func update(id: String,
                _ input: UpdateHoldingInput,
                currencyManager: CurrencyManager) async {
        do {
            try await holdingRepo.update(id: id, input)
            // Refetch the row — PATCH doesn't echo the full record.
            holdings = try await holdingRepo.fetchAll()
            if let updated = holdings.first(where: { $0.id == id }) {
                await refreshParentAsset(id: updated.assetId)
            }
            recomputeSummary(currencyManager: currencyManager)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(holding: InvestmentHolding,
                currencyManager: CurrencyManager) async {
        do {
            try await holdingRepo.delete(id: holding.id)
            holdings.removeAll { $0.id == holding.id }
            await refreshParentAsset(id: holding.assetId)
            recomputeSummary(currencyManager: currencyManager)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Refetches a single Asset and replaces it in `assetsForPortfolio`.
    /// The DB trigger writes the new `current_value` synchronously, so
    /// a regular GET sees the updated row.
    private func refreshParentAsset(id: String) async {
        do {
            let assets = try await assetRepo.fetchAll()
            assetsForPortfolio = assets.filter { $0.category == .investment || $0.category == .crypto }
        } catch {
            AppLogger.data.warning("refresh parent asset: \(error.localizedDescription)")
        }
    }

    // MARK: - Computation

    /// Rebuilds `summary` from the current `holdings` + `assetsForPortfolio`
    /// + `currencyManager.rates`. Cheap; called after every mutation.
    private func recomputeSummary(currencyManager: CurrencyManager) {
        let assetsById = Dictionary(
            assetsForPortfolio.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let rates: [String: Decimal] = currencyManager.rates.reduce(into: [:]) { acc, pair in
            acc[pair.key] = Decimal(pair.value)
        }
        summary = PortfolioCalculator.aggregate(
            holdings: holdings,
            assetsById: assetsById,
            fxRates: rates,
            baseCurrency: currencyManager.dataCurrency
        )
    }
}
