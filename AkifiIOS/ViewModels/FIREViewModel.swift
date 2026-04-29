import Foundation
import Observation

/// Observable facade for the FIRE-projection screen. Pulls a savings-
/// rate snapshot from the user's actual transaction history (via
/// `SavingsRateCalculator`), pulls investable net worth from
/// `NetWorthCalculator`, and runs `FIREProjector` over both.
///
/// Re-runs only when the user changes the slider / toggle, so the
/// "live" feel doesn't pay for a recomputed transaction sweep on
/// every drag — `recomputeProjection` reuses the snapshot until the
/// next `load()`.
@MainActor
@Observable
final class FIREViewModel {
    /// Last-computed snapshot of the user's monthly cash flow.
    /// `confidence == .low` and `sampleMonths < minSampleMonths`
    /// means we hide the FIRE number and show "need more data".
    var rate: SavingsRateCalculator.Snapshot = .empty

    /// Investable net worth in base-currency minor units. Toggle
    /// `includeIlliquid` recomputes this from the breakdown.
    var netWorth: Int64 = 0

    /// Latest projection. `.unknown` while we can't compute one yet.
    var projection: FIREProjector.Projection = .unknown

    /// Slider position — what fraction of the user's net monthly
    /// disposable income to commit to investing each month.
    /// `1.0` = invest everything saved; `0.5` = half. Persisted in
    /// UserDefaults so the screen remembers the last setting.
    var investedFractionOfNet: Double {
        didSet {
            UserDefaults.standard.set(investedFractionOfNet, forKey: Self.investedFractionKey)
            recomputeProjection()
        }
    }

    /// Toggle: include illiquid assets (real estate, vehicles,
    /// collectibles) when computing net worth used for FIRE.
    /// Default is false (FIRE-community standard).
    var includeIlliquid: Bool {
        didSet {
            UserDefaults.standard.set(includeIlliquid, forKey: Self.includeIlliquidKey)
            recomputeNetWorthAndProjection()
        }
    }

    /// User-defined monthly expenses to use instead of `rate.avgMonthlyExpense
    /// + rate.monthlySubscriptionCost`. Useful when shared accounts inflate
    /// the auto-detected expense (e.g. one user covers groceries for the
    /// whole household, the auto number doesn't separate "my share"). nil
    /// means "use the auto-computed value". Persisted across launches.
    var overrideMonthlyExpenses: Int64? {
        didSet {
            if let v = overrideMonthlyExpenses {
                UserDefaults.standard.set(v, forKey: Self.overrideExpensesKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.overrideExpensesKey)
            }
            recomputeProjection()
        }
    }

    /// User-defined monthly investment contribution to use instead of
    /// `rate.avgMonthlyNet × investedFraction`. nil means "use auto×slider".
    var overrideMonthlyContribution: Int64? {
        didSet {
            if let v = overrideMonthlyContribution {
                UserDefaults.standard.set(v, forKey: Self.overrideContributionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.overrideContributionKey)
            }
            recomputeProjection()
        }
    }

    /// Whether either override is active. The UI uses this to switch
    /// between "actual savings rate" and "manual mode" copy.
    var isManualMode: Bool {
        overrideMonthlyExpenses != nil || overrideMonthlyContribution != nil
    }

    /// Last `NetWorthCalculator.Breakdown` we were handed by `load(...)`.
    /// Cached so the toggle can recompute the net worth without
    /// re-fetching everything.
    private var breakdown: NetWorthCalculator.Breakdown?

    /// The user's *current* baseline savings — same as `rate.avgMonthlyNet`
    /// at load time. Cached so `recomputeProjection` can multiply by the
    /// slider without recomputing the snapshot.
    private var monthlyDisposable: Int64 = 0

    /// Minimum non-empty months we require before showing a number.
    /// Mirrors `CashFlowEngine.confidence` — below this threshold, the
    /// projection is too noisy to take seriously.
    static let minSampleMonths = 2

    private static let includeIlliquidKey = "fire.includeIlliquid"
    private static let investedFractionKey = "fire.investedFraction"
    private static let overrideExpensesKey = "fire.overrideMonthlyExpenses"
    private static let overrideContributionKey = "fire.overrideMonthlyContribution"

    init() {
        let stored = UserDefaults.standard.object(forKey: Self.investedFractionKey) as? Double
        self.investedFractionOfNet = stored ?? 1.0
        self.includeIlliquid = UserDefaults.standard.bool(forKey: Self.includeIlliquidKey)
        // UserDefaults stores numbers as Int64 only via NSNumber — read
        // through `object(forKey:)` so we can disambiguate "0 saved"
        // (a real override of zero) from "never saved" (use auto).
        self.overrideMonthlyExpenses = (UserDefaults.standard.object(forKey: Self.overrideExpensesKey) as? NSNumber)?.int64Value
        self.overrideMonthlyContribution = (UserDefaults.standard.object(forKey: Self.overrideContributionKey) as? NSNumber)?.int64Value
    }

    /// Resolved monthly expenses (override when set, otherwise the
    /// auto-detected value).
    var resolvedMonthlyExpenses: Int64 {
        overrideMonthlyExpenses ?? (rate.avgMonthlyExpense + rate.monthlySubscriptionCost)
    }

    /// Resolved monthly contribution (override when set, otherwise
    /// auto-net × slider fraction).
    var resolvedMonthlyContribution: Int64 {
        overrideMonthlyContribution ?? Int64(Double(max(rate.avgMonthlyNet, 0)) * investedFractionOfNet)
    }

    // MARK: - Public API

    /// Pull fresh inputs and recompute everything once. The screen
    /// calls this from `.task` and on pull-to-refresh.
    func load(
        dataStore: DataStore,
        currencyManager: CurrencyManager,
        breakdown: NetWorthCalculator.Breakdown
    ) {
        self.breakdown = breakdown

        let baseCode = currencyManager.dataCurrency.rawValue
        let accountsById = Dictionary(
            dataStore.accounts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let fxRates: [String: Decimal] = currencyManager.rates.reduce(into: [:]) { acc, pair in
            acc[pair.key] = Decimal(pair.value)
        }

        rate = SavingsRateCalculator.compute(
            transactions: dataStore.transactions,
            subscriptions: dataStore.subscriptions,
            now: Date(),
            calendar: Calendar(identifier: .gregorian),
            accountsById: accountsById,
            fxRates: fxRates,
            baseCode: baseCode
        )
        monthlyDisposable = max(rate.avgMonthlyNet, 0)

        recomputeNetWorthAndProjection()
    }

    /// True when we have enough months of activity to project. Below
    /// this, the screen shows an onboarding state instead of bogus
    /// FIRE dates — UNLESS the user has overridden expenses manually,
    /// in which case the manual numbers carry the projection.
    var hasEnoughData: Bool {
        if overrideMonthlyExpenses != nil { return true }
        return rate.sampleMonths >= Self.minSampleMonths
            && rate.avgMonthlyExpense > 0
    }

    /// Snapshot of the projection's inputs for the dashboard tease
    /// card on `NetWorthDashboardView`. Lightweight on purpose so we
    /// can recompute it cheaply elsewhere.
    func snippet() -> FIRESnippet {
        FIRESnippet(
            yearsToFIRE: projection.yearsToFIRE,
            confidence: rate.confidence,
            hasEnoughData: hasEnoughData
        )
    }

    // MARK: - Private

    /// Slider mutation only: monthly contribution = max(0, net) × fraction.
    /// When the user has set a manual expense / contribution override,
    /// those values take precedence over the auto-derived ones.
    private func recomputeProjection() {
        guard hasEnoughData else {
            projection = .unknown
            return
        }
        projection = FIREProjector.project(
            currentNetWorth: netWorth,
            monthlyContribution: resolvedMonthlyContribution,
            monthlyExpenses: resolvedMonthlyExpenses,
            disposableMonthly: monthlyDisposable
        )
    }

    /// Toggle mutation: re-derive net worth from `breakdown`, then run
    /// the projection again. Investable = accounts + investment +
    /// crypto + cash; including illiquid adds real estate, vehicles
    /// and collectibles.
    private func recomputeNetWorthAndProjection() {
        guard let breakdown else { return }
        netWorth = computedNetWorth(breakdown: breakdown)
        recomputeProjection()
    }

    private func computedNetWorth(breakdown: NetWorthCalculator.Breakdown) -> Int64 {
        var nw = breakdown.accountsTotal
        let investableCategories: Set<AssetCategory> = [.investment, .crypto, .cash]
        let illiquidCategories: Set<AssetCategory> = [.realEstate, .vehicle, .collectible, .other]
        for (category, amount) in breakdown.byAssetCategory {
            if investableCategories.contains(category) {
                nw += amount
            } else if includeIlliquid && illiquidCategories.contains(category) {
                nw += amount
            }
        }
        nw -= breakdown.liabilitiesTotal
        return nw
    }
}

/// Compact FIRE summary for the NetWorth dashboard tease card.
struct FIRESnippet: Sendable, Equatable {
    let yearsToFIRE: Decimal?
    let confidence: CashFlowEngine.Confidence
    let hasEnoughData: Bool
}
