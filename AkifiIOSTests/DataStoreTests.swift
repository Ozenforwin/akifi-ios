import XCTest
@testable import AkifiIOS

/// Tests covering the cached FX-context that powers `DataStore.amountInBase(_:)`
/// and `DataStore.currencyContext`. The Phase 1 performance fix moved the
/// `[String: Account]` and `[String: Decimal]` rebuilds out of the per-call
/// hot path and into `rebuildCurrencyContext()`. These tests pin down two
/// invariants:
///
/// 1. After `rebuildCaches()` runs, `amountInBaseDisplay(_:)` returns the
///    correct FX-normalized value.
/// 2. A duplicate `account.id` (which can leak in from shared-account
///    JOIN responses) does not crash the cache rebuild.
@MainActor
final class DataStoreTests: XCTestCase {

    // MARK: - Fixtures

    /// USD-pivoted rates (matches `ExchangeRateService` convention). Round
    /// numbers so kopeck assertions stay transparent.
    private let rates: [String: Double] = [
        "USD": 1.0,
        "RUB": 100.0,
        "EUR": 0.92
    ]

    private func makeRubAccount(id: String = "acc-rub") -> Account {
        Account(
            id: id,
            userId: "u1",
            name: "Семейный",
            icon: "🏠",
            color: "#3B82F6",
            initialBalance: 100_000_00,    // 100 000 ₽
            currency: "RUB"
        )
    }

    private func makeUsdAccount(id: String = "acc-usd") -> Account {
        Account(
            id: id,
            userId: "u1",
            name: "ByBit",
            icon: "💰",
            color: "#F59E0B",
            initialBalance: 500_00,        // 500 $
            currency: "USD"
        )
    }

    /// 20 USD expense booked on the USD account. After FX-normalization to
    /// the RUB base (100 RUB / 1 USD), this should aggregate to 2 000 ₽.
    private func makeUsdCoffeeOnUsdAccount() -> Transaction {
        Transaction(
            id: "tx-coffee",
            userId: "u1",
            accountId: "acc-usd",
            amount: 20_00,
            amountNative: 20_00,
            currency: "USD",
            description: "Coffee",
            categoryId: nil,
            type: .expense,
            date: "2026-04-20",
            merchantName: nil,
            merchantFuzzy: nil,
            transferGroupId: nil,
            status: nil,
            createdAt: nil,
            updatedAt: nil
        )
    }

    private func makeStore(
        accounts: [Account],
        transactions: [Transaction] = [],
        baseCurrency: CurrencyCode = .rub
    ) -> DataStore {
        let store = DataStore()
        let cm = CurrencyManager()
        cm.dataCurrency = baseCurrency
        cm.selectedCurrency = baseCurrency
        cm.rates = rates
        store.currencyManager = cm
        store.accounts = accounts
        store.transactions = transactions
        store.rebuildCaches()
        return store
    }

    // MARK: - amountInBaseDisplay after rebuildCaches()

    /// After `rebuildCaches()` populates the FX-context cache,
    /// `amountInBaseDisplay(_:)` must return the converted value (RUB
    /// kopecks / 100), not the raw `amountNative`.
    func test_amountInBaseDisplay_afterRebuildCaches_returnsFxNormalizedValue() {
        let store = makeStore(
            accounts: [makeRubAccount(), makeUsdAccount()],
            transactions: [makeUsdCoffeeOnUsdAccount()]
        )

        let display = store.amountInBaseDisplay(makeUsdCoffeeOnUsdAccount())

        // 20 USD × (100 RUB / 1 USD) = 2 000 RUB.
        XCTAssertEqual(display, Decimal(2_000), "USD coffee should normalize to 2 000 ₽")
    }

    /// `currencyContext` is the canonical bundle every engine takes — it
    /// must reflect the same cached snapshot as `amountInBase(_:)`.
    func test_currencyContext_returnsCachedSnapshot() {
        let store = makeStore(accounts: [makeRubAccount(), makeUsdAccount()])

        let ctx = store.currencyContext

        XCTAssertEqual(ctx.baseCode, "RUB")
        XCTAssertEqual(ctx.accountsById.count, 2)
        XCTAssertEqual(ctx.accountsById["acc-rub"]?.currency, "RUB")
        XCTAssertEqual(ctx.accountsById["acc-usd"]?.currency, "USD")
        XCTAssertEqual(ctx.fxRates["USD"], Decimal(1.0))
        XCTAssertEqual(ctx.fxRates["RUB"], Decimal(100.0))
    }

    /// Calling `currencyContextDidChange()` after a base-currency swap must
    /// rebuild the cache — `amountInBase(_:)` should pick up the new base.
    func test_currencyContextDidChange_picksUpNewBaseCurrency() {
        let store = makeStore(
            accounts: [makeRubAccount(), makeUsdAccount()],
            transactions: [makeUsdCoffeeOnUsdAccount()]
        )

        // Initial: base = RUB, 20 USD → 2 000 RUB → 200 000 kopecks.
        XCTAssertEqual(store.amountInBase(makeUsdCoffeeOnUsdAccount()), 2_000_00)

        // Swap base to USD; rates are USD-pivoted so 1 USD == 100 cents.
        store.currencyManager?.dataCurrency = .usd
        store.currencyContextDidChange()

        XCTAssertEqual(store.amountInBase(makeUsdCoffeeOnUsdAccount()), 20_00,
                       "After base swap to USD, 20 USD stays 20 USD = 2 000 cents")
    }

    // MARK: - Duplicate account_id resilience

    /// Shared-account joins can return the same `account_id` twice. The
    /// FX-context rebuild must not crash on duplicate keys (the previous
    /// `Dictionary(uniqueKeysWithValues:)` form trapped here).
    func test_rebuildCaches_withDuplicateAccountId_doesNotCrash() {
        let dup1 = makeRubAccount(id: "acc-shared")
        // Same id, different display name — represents the legacy "same
        // physical account, two membership rows" scenario.
        let dup2 = Account(
            id: "acc-shared",
            userId: "u2",
            name: "Семейный (mirror)",
            icon: "🏠",
            color: "#3B82F6",
            initialBalance: 100_000_00,
            currency: "RUB"
        )

        let store = DataStore()
        let cm = CurrencyManager()
        cm.dataCurrency = .rub
        cm.rates = rates
        store.currencyManager = cm
        store.accounts = [dup1, dup2]

        // The bug: `Dictionary(uniqueKeysWithValues:)` traps on duplicates.
        // The fix uses `uniquingKeysWith` and keeps the first occurrence.
        store.rebuildCaches()

        let ctx = store.currencyContext
        XCTAssertEqual(ctx.accountsById.count, 1, "Duplicates must be coalesced, not crash")
        XCTAssertNotNil(ctx.accountsById["acc-shared"])
    }
}
