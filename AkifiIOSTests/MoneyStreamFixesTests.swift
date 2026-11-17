import XCTest
import Supabase
@testable import AkifiIOS

// Regression tests for the 2026-11-17 review, money stream
// (M1 M2 M3 M5 M7 M10 M11 M12, D8, B6, B7, historical FX date).

// MARK: - Fixtures

private enum Fx {
    /// USD-pivoted (1 USD = X), the `CurrencyManager.rates` convention.
    static let rates: [String: Double] = ["USD": 1.0, "RUB": 92.5, "EUR": 0.92, "JPY": 150.0]
    static var decimalRates: [String: Decimal] { rates.mapValues { Decimal($0) } }

    static func account(_ id: String, currency: String, initial: Int64 = 0, owner: String = "u1") -> Account {
        Account(id: id, userId: owner, name: id, icon: "💳", color: "#000000",
                initialBalance: initial, currency: currency)
    }

    static func tx(
        _ id: String,
        account: String?,
        native: Int64,
        type: TransactionType,
        user: String = "u1",
        label: String? = nil,
        date: String = "2026-11-10",
        categoryId: String? = nil,
        transferGroupId: String? = nil,
        autoTransferGroupId: String? = nil,
        foreignAmount: Decimal? = nil,
        foreignCurrency: String? = nil,
        fxRate: Decimal? = nil,
        merchant: String? = nil
    ) -> Transaction {
        Transaction(
            id: id, userId: user, accountId: account,
            amount: native, amountNative: native, currency: label,
            foreignAmount: foreignAmount, foreignCurrency: foreignCurrency, fxRate: fxRate,
            description: nil, categoryId: categoryId, type: type, date: date,
            merchantName: merchant, merchantFuzzy: nil, transferGroupId: transferGroupId,
            autoTransferGroupId: autoTransferGroupId,
            status: nil, createdAt: nil, updatedAt: nil
        )
    }

    static func category(_ id: String, name: String, type: CategoryType = .expense, owner: String = "u1") -> AkifiIOS.Category {
        AkifiIOS.Category(id: id, userId: owner, accountId: nil, name: name, icon: "🛒",
                          color: "#000000", type: type, isActive: true, createdAt: nil)
    }

    static func sub(_ amount: Int64, currency: String, period: BillingPeriod = .monthly, name: String = "Sub") -> SubscriptionTracker {
        SubscriptionTracker(
            id: UUID().uuidString, userId: "u1", serviceName: name,
            amount: amount, currency: currency,
            billingPeriod: period, startDate: "2026-01-01",
            lastPaymentDate: nil, nextPaymentDate: nil,
            categoryId: nil, reminderDays: 1, iconColor: nil,
            isActive: true, status: .active
        )
    }
}

// MARK: - M1 native balance

@MainActor
final class NativeBalanceTests: XCTestCase {

    private func store(accounts: [Account], transactions: [Transaction]) -> DataStore {
        let store = DataStore()
        let cm = CurrencyManager()
        cm.dataCurrency = .rub
        cm.selectedCurrency = .rub
        cm.rates = Fx.rates
        store.currencyManager = cm
        store.accounts = accounts
        store.transactions = transactions
        store.rebuildCaches()
        return store
    }

    /// The M1 scenario: a $640 USD account with a RUB base. The form must
    /// prefill "640", not the base-currency "59200".
    func test_usdAccount_nativeBalanceStaysInDollars() {
        let bybit = Fx.account("bybit", currency: "USD", initial: 500_00)
        let rows = [
            Fx.tx("in", account: "bybit", native: 200_00, type: .income),
            Fx.tx("out", account: "bybit", native: 60_00, type: .expense)
        ]
        let s = store(accounts: [bybit], transactions: rows)

        XCTAssertEqual(s.nativeBalance(for: bybit), 640_00)
        XCTAssertEqual(s.nativeNet(for: bybit), 140_00)
        XCTAssertEqual(AccountFormView.balanceText(s.nativeBalance(for: bybit)), "640")
        // `balance(for:)` is the BASE figure — exactly what the form used to show.
        XCTAssertEqual(s.balance(for: bybit), 59_200_00)
    }

    /// Same sign rules as `rebuildCaches`: transfer legs move money, a
    /// legacy `.transfer` row carries its own sign, other accounts' rows
    /// don't count. Converted to base it equals `balance(for:)`.
    func test_signRules_matchRebuildCaches_includingTransfers() {
        let usd = Fx.account("usd", currency: "USD", initial: 100_00)
        let rub = Fx.account("rub", currency: "RUB", initial: 10_000_00)
        let rows = [
            Fx.tx("e", account: "usd", native: 25_00, type: .expense),
            // Transfer USD → RUB: out-leg on USD, in-leg on RUB (own currencies).
            Fx.tx("t-out", account: "usd", native: 10_00, type: .expense, transferGroupId: "g1"),
            Fx.tx("t-in", account: "rub", native: 925_00, type: .income, transferGroupId: "g1"),
            // Legacy signed transfer rows.
            Fx.tx("legacy-neg", account: "usd", native: -5_00, type: .transfer),
            Fx.tx("legacy-pos", account: "usd", native: 2_00, type: .transfer),
            Fx.tx("other", account: "rub", native: 1_00, type: .expense)
        ]
        let s = store(accounts: [usd, rub], transactions: rows)

        // 100 − 25 − 10 − 5 + 2 = 62 USD
        XCTAssertEqual(s.nativeBalance(for: usd), 62_00)
        // 10 000 + 925 − 1 = 10 924 RUB
        XCTAssertEqual(s.nativeBalance(for: rub), 10_924_00)

        let toBase = NetWorthCalculator.convert(amount: s.nativeBalance(for: usd), from: "USD", to: "RUB", rates: Fx.decimalRates)
        XCTAssertEqual(toBase, s.balance(for: usd))
        XCTAssertEqual(s.nativeBalance(for: rub), s.balance(for: rub))
    }

    /// Backing into `initial_balance` (whole units in the DB) rounds half
    /// away from zero instead of the repository's truncation.
    func test_initialBalanceForDesiredBalance_roundsToWholeUnits() {
        XCTAssertEqual(NativeBalance.initialBalance(forDesiredBalance: 640_00, net: 140_00), 500_00)
        XCTAssertEqual(NativeBalance.initialBalance(forDesiredBalance: 640_00, net: 140_49), 500_00) // 499.51 → 500
        XCTAssertEqual(NativeBalance.initialBalance(forDesiredBalance: 640_00, net: 140_51), 499_00) // 499.49 → 499
        XCTAssertEqual(NativeBalance.initialBalance(forDesiredBalance: 0, net: 12_50), -13_00)       // −12.50 → −13
        XCTAssertEqual(NativeBalance.initialBalance(forDesiredBalance: 0, net: -12_50), 13_00)
    }

    func test_balanceText_roundTripsKopecks() {
        XCTAssertEqual(AccountFormView.balanceText(640_55), "640.55")
        XCTAssertEqual(AccountFormView.balanceText(-123_45), "-123.45")
        XCTAssertEqual(AccountFormView.balanceText(-1_00), "-1")
        XCTAssertEqual(AccountFormView.balanceText(0), "0")
        for k: Int64 in [640_55, -123_45, 1, -1, 99_99] {
            XCTAssertEqual(Decimal(string: AccountFormView.balanceText(k))?.kopecks, k)
        }
    }

    /// Carousel month chips: this month only, transfers excluded, base currency.
    func test_currentMonthFlow_isThisMonthOnly() {
        let usd = Fx.account("usd", currency: "USD")
        let rows = [
            Fx.tx("now-in", account: "usd", native: 10_00, type: .income, date: "2026-11-03"),
            Fx.tx("now-out", account: "usd", native: 2_00, type: .expense, date: "2026-11-15"),
            Fx.tx("old", account: "usd", native: 99_00, type: .income, date: "2026-10-31"),
            Fx.tx("leg", account: "usd", native: 50_00, type: .income, date: "2026-11-05", transferGroupId: "g")
        ]
        let s = store(accounts: [usd], transactions: rows)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Novosibirsk")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 1))!

        let flow = s.currentMonthFlow(for: usd, now: now, calendar: cal)
        XCTAssertEqual(flow.monthKey, "2026-11")
        XCTAssertEqual(flow.income, 925_00)   // 10 USD in base
        XCTAssertEqual(flow.expense, 185_00)  // 2 USD in base
    }

    /// 01:00 on the 1st in UTC+7 is still the previous month in UTC; the
    /// key must follow the user's calendar (tx.date is local).
    func test_monthKey_usesLocalCalendar() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Novosibirsk")!
        let firstOfDecLocal = cal.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 1))!
        XCTAssertEqual(DataStore.monthKey(for: firstOfDecLocal, calendar: cal), "2026-12")
    }

    func test_mainExpenseForAutoTransferLeg() {
        let main = Fx.tx("main", account: "shared", native: 100_00, type: .expense, autoTransferGroupId: "g")
        let out = Fx.tx("out", account: "card", native: 100_00, type: .expense, transferGroupId: "g", autoTransferGroupId: "g")
        let inLeg = Fx.tx("in", account: "shared", native: 100_00, type: .income, transferGroupId: "g", autoTransferGroupId: "g")
        let all = [main, out, inLeg]
        XCTAssertEqual(DataStore.mainExpense(forAutoTransferLeg: out, in: all)?.id, "main")
        XCTAssertEqual(DataStore.mainExpense(forAutoTransferLeg: inLeg, in: all)?.id, "main")
        XCTAssertNil(DataStore.mainExpense(forAutoTransferLeg: main, in: all), "the expense itself is not a leg")
        XCTAssertNil(DataStore.mainExpense(forAutoTransferLeg: out, in: [out, inLeg]), "hidden by RLS")
    }
}

// MARK: - M3 / M10 / M12 entry amounts & rounding

final class EntryAmountTests: XCTestCase {

    /// M3: KZT is not in the rate table — 100 USD on a KZT account must be
    /// refused, never stored as 100 ₸ with fx_rate 1.
    func test_missingRate_refusesInsteadOfOneToOne() {
        XCTAssertThrowsError(try TransactionFormView.entryAmounts(
            amount: 100, entryCurrency: "USD", accountCurrency: "KZT", rates: Fx.rates
        )) { error in
            XCTAssertEqual(error as? MissingFXRateError, MissingFXRateError(from: "USD", to: "KZT"))
            XCTAssertFalse((error.localizedDescription).isEmpty)
        }
        XCTAssertThrowsError(try TransactionMath.convertForStorage(100, from: "USD", to: "RUB", rates: ["USD": 1.0, "RUB": 0]))
        XCTAssertThrowsError(try TransactionMath.convertForStorage(100, from: "GEL", to: "RUB", rates: Fx.rates))
    }

    func test_sameCurrency_needsNoRate() throws {
        let e = try TransactionFormView.entryAmounts(amount: 100, entryCurrency: "kzt", accountCurrency: "KZT", rates: [:])
        XCTAssertEqual(e, .init(native: 100, foreignAmount: nil, foreignCurrency: nil, fxRate: nil))
    }

    func test_crossCurrency_convertsAndRoundsForAccountCurrency() throws {
        let e = try TransactionFormView.entryAmounts(amount: Decimal(string: "12.34")!, entryCurrency: "USD", accountCurrency: "RUB", rates: Fx.rates)
        XCTAssertEqual(e.native, Decimal(string: "1141.45"))        // 1141.45 exactly (12.34 × 92.5)
        XCTAssertEqual(e.foreignAmount, Decimal(string: "12.34"))
        XCTAssertEqual(e.foreignCurrency, "USD")
        XCTAssertEqual(e.fxRate, Decimal(string: "1141.45")! / Decimal(string: "12.34")!)

        // Zero-decimal account currency → whole yen.
        let jpy = try TransactionMath.convertForStorage(Decimal(string: "10.01")!, from: "USD", to: "JPY", rates: Fx.rates)
        XCTAssertEqual(jpy, 1502)                                    // 1501.5 → 1502
        // Binary-float rates do not leak into the stored value.
        let eur = try TransactionMath.convertForStorage(100, from: "USD", to: "EUR", rates: Fx.rates)
        XCTAssertEqual(eur, 92)
    }

    /// M10: unchanged amount + currency + account keeps the frozen rate.
    func test_unchangedEdit_keepsStoredFxRate() throws {
        let stored = Fx.tx("t", account: "rub", native: 9_250_00, type: .expense,
                           foreignAmount: 100, foreignCurrency: "USD", fxRate: Decimal(string: "92.5"))
        let todayRates: [String: Double] = ["USD": 1.0, "RUB": 95.0]

        let kept = try TransactionFormView.entryAmounts(
            amount: 100, entryCurrency: "USD", accountCurrency: "RUB", rates: todayRates, unchangedOriginal: stored
        )
        XCTAssertEqual(kept.native, 9250)
        XCTAssertEqual(kept.fxRate, Decimal(string: "92.5"))

        // Amount changed → today's rate.
        let repriced = try TransactionFormView.entryAmounts(
            amount: 101, entryCurrency: "USD", accountCurrency: "RUB", rates: todayRates, unchangedOriginal: stored
        )
        XCTAssertEqual(repriced.native, 9595)
        // Without the "unchanged" signal the caller gets a fresh conversion.
        let fresh = try TransactionFormView.entryAmounts(amount: 100, entryCurrency: "USD", accountCurrency: "RUB", rates: todayRates)
        XCTAssertEqual(fresh.native, 9500)
    }

    /// M12: one rule — half away from zero — on every path.
    func test_kopecks_halfAwayFromZero() {
        XCTAssertEqual(Decimal(string: "0.285")!.kopecks, 29)
        XCTAssertEqual(Decimal(string: "0.005")!.kopecks, 1)
        XCTAssertEqual(Decimal(string: "-0.005")!.kopecks, -1)
        XCTAssertEqual(Decimal(string: "-0.285")!.kopecks, -29)
        XCTAssertEqual(Decimal(string: "12.344")!.kopecks, 1234)
        // A binary Double that is "really" 0.285 still rounds up.
        XCTAssertEqual(MoneyRounding.kopecks(MoneyRounding.decimal(fromJSONNumber: 0.285)), 29)
    }

    /// The string path used to truncate (0.285 → 28) while the number path
    /// rounded (→ 29). Both now decode the same kopecks.
    func test_decodeKopecks_stringAndNumberAgree() throws {
        func decode(_ amountJSON: String) throws -> Transaction {
            let json = """
            {"id":"t","user_id":"u","account_id":"a","amount":\(amountJSON),"amount_native":\(amountJSON),
             "currency":"RUB","type":"expense","date":"2026-11-17T00:30:00+00:00"}
            """
            return try JSONDecoder().decode(Transaction.self, from: Data(json.utf8))
        }
        for (str, num, expected) in [("\"0.285\"", "0.285", Int64(29)),
                                     ("\"1141.455\"", "1141.455", 114146),
                                     ("\"-0.005\"", "-0.005", -1),
                                     ("\"92.5\"", "92.5", 9250)] {
            XCTAssertEqual(try decode(str).amountNative, expected, str)
            XCTAssertEqual(try decode(num).amountNative, expected, num)
        }
    }

    func test_storageScale_isoDigitsCappedAtTwo() {
        XCTAssertEqual(MoneyRounding.storageScale(forCurrency: "USD"), 2)
        XCTAssertEqual(MoneyRounding.storageScale(forCurrency: "rub"), 2)  // display hides kopecks, storage keeps them
        XCTAssertEqual(MoneyRounding.storageScale(forCurrency: "JPY"), 0)
        XCTAssertEqual(MoneyRounding.storageScale(forCurrency: "KWD"), 2)  // 3 ISO digits, kopeck storage
    }
}

// MARK: - TransferFormView legs (M3 / M10)

@MainActor
final class TransferLegFixTests: XCTestCase {

    func test_missingRate_throws() {
        XCTAssertThrowsError(try TransferFormView.legFields(
            amountValue: 100, entryCurrency: .usd, account: Fx.account("kzt", currency: "KZT"), rates: Fx.rates
        ))
    }

    func test_unchangedLeg_keptVerbatim() throws {
        let stored = Fx.tx("leg", account: "rub", native: 9_250_00, type: .income, transferGroupId: "g",
                           foreignAmount: 100, foreignCurrency: "USD", fxRate: Decimal(string: "92.5"))
        let leg = try TransferFormView.legFields(
            amountValue: 100, entryCurrency: .usd, account: Fx.account("rub", currency: "RUB"),
            rates: ["USD": 1.0, "RUB": 95.0], unchangedLeg: stored
        )
        XCTAssertEqual(leg.amountInAccount, 9250)
        XCTAssertEqual(leg.fxRate, Decimal(string: "92.5"))
        XCTAssertEqual(leg.foreignCurrency, "USD")

        // A stored leg of ANOTHER account is never reused.
        let other = try TransferFormView.legFields(
            amountValue: 100, entryCurrency: .usd, account: Fx.account("rub2", currency: "RUB"),
            rates: ["USD": 1.0, "RUB": 95.0], unchangedLeg: stored
        )
        XCTAssertEqual(other.amountInAccount, 9500)
    }

    func test_expenseNameFromLegDescription() {
        XCTAssertEqual(TransferFormView.expenseName(fromLegDescription: "Авто-перевод: Кафе"), "Кафе")
        XCTAssertEqual(TransferFormView.expenseName(fromLegDescription: "Кафе"), "Кафе")
    }
}

// MARK: - D8 timestamps & historical FX date

final class FormDateTests: XCTestCase {
    private let utc7 = TimeZone(identifier: "Asia/Novosibirsk")!

    private func localComponents(_ date: Date) -> DateComponents {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc7
        return cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    /// A server row keeps its wall-clock time and round-trips byte-for-byte.
    func test_parse_serverTimestamp_keepsWallClock() throws {
        let raw = "2026-11-17T00:30:00+00:00"
        let date = try XCTUnwrap(TransactionFormDates.parse(rawDateTime: raw, fallbackDate: "2026-11-17", timeZone: utc7))
        let c = localComponents(date)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute], [2026, 11, 17, 0, 30])
        XCTAssertEqual(TransactionFormDates.string(from: date, timeZone: utc7), "2026-11-17T00:30:00")
    }

    func test_parse_variants() throws {
        for raw in ["2026-11-17T21:52:38+00:00", "2026-11-17T21:52:38.123456+00:00",
                    "2026-11-17 21:52:38+00", "2026-11-17T21:52:38"] {
            let date = try XCTUnwrap(TransactionFormDates.parse(rawDateTime: raw, fallbackDate: "2026-11-17", timeZone: utc7), raw)
            XCTAssertEqual(TransactionFormDates.string(from: date, timeZone: utc7), "2026-11-17T21:52:38", raw)
        }
        let dayOnly = try XCTUnwrap(TransactionFormDates.parse(rawDateTime: "2026-11-17", fallbackDate: "2026-11-17", timeZone: utc7))
        XCTAssertEqual(TransactionFormDates.string(from: dayOnly, timeZone: utc7), "2026-11-17T00:00:00")
    }

    /// Local midnight of the 17th in UTC+7 is the 16th in GMT — the quote
    /// must be for the 17th.
    func test_historicalDateKey_usesLocalDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc7
        let localMidnight = cal.date(from: DateComponents(year: 2026, month: 11, day: 17))!
        XCTAssertEqual(ExchangeRateService.historicalDateKey(for: localMidnight, timeZone: utc7), "2026-11-17")
    }
}

// MARK: - B6 category filter, M7 totals, B7 sharing

@MainActor
final class TransactionsListFixTests: XCTestCase {

    /// Both members of a shared account have their own «Продукты»; the
    /// chip (one per name + type) matches both.
    func test_categoryFilter_matchesSameNameAcrossMembers() {
        let mine = Fx.category("c-mine", name: "Продукты", owner: "a")
        let partners = Fx.category("c-partner", name: " продукты", owner: "b")
        let incomeSameName = Fx.category("c-income", name: "Продукты", type: .income, owner: "b")
        let all = [mine, partners, incomeSameName]
        let filter = TransactionCategoryFilter(selectedIds: ["c-mine"], categories: all)
        let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

        let partnerRow = Fx.tx("1", account: "shared", native: 1, type: .expense, user: "b", categoryId: "c-partner")
        let incomeRow = Fx.tx("2", account: "shared", native: 1, type: .income, user: "b", categoryId: "c-income")
        let uncategorised = Fx.tx("3", account: "shared", native: 1, type: .expense)
        let hiddenCategory = Fx.tx("4", account: "shared", native: 1, type: .expense, categoryId: "c-mine")

        XCTAssertTrue(filter.matches(partnerRow, category: byId["c-partner"]))
        XCTAssertFalse(filter.matches(incomeRow, category: byId["c-income"]), "type is part of the key")
        XCTAssertFalse(filter.matches(uncategorised, category: nil), "an active filter hides uncategorised rows")
        XCTAssertTrue(filter.matches(hiddenCategory, category: nil), "unresolved category still matches by id")

        let off = TransactionCategoryFilter(selectedIds: [], categories: all)
        XCTAssertTrue(off.matches(uncategorised, category: nil))
    }

    /// M7: `$50 + 3 000 ₽` is ~7 625 ₽, not «3 050 ₽».
    func test_summaryTotals_areInBase() {
        let accounts = ["usd": Fx.account("usd", currency: "USD"), "rub": Fx.account("rub", currency: "RUB")]
        let rows = [
            Fx.tx("u", account: "usd", native: 50_00, type: .expense),
            Fx.tx("r", account: "rub", native: 3_000_00, type: .expense),
            Fx.tx("i", account: "usd", native: 10_00, type: .income),
            Fx.tx("t1", account: "usd", native: 1_00, type: .expense, transferGroupId: "g"),
            Fx.tx("t2", account: "rub", native: 92_50, type: .income, transferGroupId: "g")
        ]
        let totals = TransactionsTabView.summaryTotals(rows) { tx in
            TransactionMath.amountInBase(tx, accountsById: accounts, fxRates: Fx.decimalRates, baseCode: "RUB")
        }
        XCTAssertEqual(totals.expense, 7_625_00)
        XCTAssertEqual(totals.income, 925_00)
        XCTAssertEqual(totals.transfer, 92_50, "one leg per transfer group")
    }

    /// B7: membership decides; a partner's rows are not required.
    func test_isShared_fromMembership() {
        let owned = Fx.account("fam", currency: "RUB", owner: "me")
        let personal = Fx.account("card", currency: "RUB", owner: "me")
        let partners = Fx.account("theirs", currency: "RUB", owner: "partner")
        let counts = ["fam": 2, "card": 1, "theirs": 2]

        XCTAssertTrue(AccountSharingIndex.isShared(owned, currentUserId: "me", memberCounts: counts) { false },
                      "freshly shared, partner has written nothing yet")
        XCTAssertFalse(AccountSharingIndex.isShared(personal, currentUserId: "me", memberCounts: counts) { true },
                       "membership beats the transaction heuristic")
        XCTAssertTrue(AccountSharingIndex.isShared(partners, currentUserId: "me", memberCounts: [:]) { false },
                      "someone else's account is shared with me by definition")
        XCTAssertTrue(AccountSharingIndex.isShared(owned, currentUserId: "me", memberCounts: nil) { true },
                      "not loaded yet → legacy heuristic")
        XCTAssertFalse(AccountSharingIndex.isShared(owned, currentUserId: "me", memberCounts: nil) { false })
    }

    /// Server rule (20261117120200): only the payer may write a triplet.
    func test_autoTransferPermission_onlyPayer() {
        let shared = Fx.account("fam", currency: "RUB", owner: "me")
        let myCard = Fx.account("my-card", currency: "RUB", owner: "me")
        var mine = Fx.tx("m1", account: "fam", native: 100_00, type: .expense, user: "me", autoTransferGroupId: "g1")
        mine.paymentSourceAccountId = "my-card"
        var partners = Fx.tx("p1", account: "fam", native: 100_00, type: .expense, user: "partner", autoTransferGroupId: "g2")
        partners.paymentSourceAccountId = "partner-card"   // invisible to me
        let partnersInLeg = Fx.tx("p1-in", account: "fam", native: 100_00, type: .income, user: "partner",
                                  transferGroupId: "g2", autoTransferGroupId: "g2")
        let plain = Fx.tx("x", account: "fam", native: 5_00, type: .expense, user: "partner")
        let all = [mine, partners, partnersInLeg, plain]
        let accounts = [shared, myCard]

        func can(_ tx: Transaction, _ uid: String? = "me") -> Bool {
            AutoTransferPermission.canModify(tx, currentUserId: uid, accounts: accounts, transactions: all)
        }
        XCTAssertTrue(can(mine))
        XCTAssertFalse(can(partners), "paid from the partner's card")
        XCTAssertFalse(can(partnersInLeg), "a leg follows its main expense")
        XCTAssertTrue(can(plain), "not an auto-transfer — RLS decides as before")
        XCTAssertTrue(can(partners, nil), "no profile yet → let the server decide")

        // Partner's card shared with me → visible → allowed.
        let sharedCard = Fx.account("partner-card", currency: "RUB", owner: "partner")
        XCTAssertTrue(AutoTransferPermission.canModify(partners, currentUserId: "me", accounts: accounts + [sharedCard], transactions: all))
    }

    func test_formErrorMessage_mapsServerGuards() {
        let payer = PostgrestError(
            hint: "Only the member who paid (owner of the source card) can edit or delete this expense.",
            code: "42501", message: "Auto-transfer g includes rows on an account you cannot edit (2 of 3 writable)")
        XCTAssertEqual(FormErrorMessage.text(for: payer), String(localized: "tx.error.onlyPayerCanEdit"))
        XCTAssertEqual(FormErrorMessage.text(for: PostgrestError(code: "42501", message: "Expense x is not editable by you")),
                       String(localized: "tx.error.noPermission"))
        XCTAssertEqual(FormErrorMessage.text(for: PostgrestError(code: "P0002", message: "Expense x not found")),
                       String(localized: "tx.error.alreadyDeleted"))
        XCTAssertEqual(FormErrorMessage.text(for: PostgrestError(
            hint: "Every amount_native on the account is stored in its currency (ADR-001). Create a new account instead.",
            code: "23514", message: "Account currency cannot change once the account has transactions")),
                       String(localized: "account.currency.locked.hint"))
        XCTAssertEqual(FormErrorMessage.text(for: PostgrestError(code: "42501", message: "Only the account owner can change the account currency")),
                       String(localized: "account.currency.ownerOnly.hint"))
        XCTAssertEqual(FormErrorMessage.text(for: MissingFXRateError(from: "USD", to: "KZT")),
                       MissingFXRateError(from: "USD", to: "KZT").localizedDescription)
    }
}

// MARK: - M5 subscriptions in forecast / savings rate / PDF, M7 PDF + CSV

final class MultiCurrencyReportFixTests: XCTestCase {

    private let accountsById = ["rub": Fx.account("rub", currency: "RUB"), "usd": Fx.account("usd", currency: "USD")]

    /// M5: $20 + 399 ₽ = 2 249 ₽ a month, not 419.
    func test_forecastAndSavingsRate_convertSubscriptions() {
        let subs = [Fx.sub(20_00, currency: "USD"), Fx.sub(399_00, currency: "RUB")]
        let forecast = CashFlowEngine.forecast(
            startingBalance: 0, transactions: [], subscriptions: subs,
            accountsById: accountsById, fxRates: Fx.decimalRates, baseCode: "RUB"
        )
        XCTAssertEqual(forecast.monthlySubscriptionCost, 2_249_00)

        let rate = SavingsRateCalculator.compute(
            transactions: [Fx.tx("i", account: "rub", native: 100_000_00, type: .income, date: Self.lastMonthDay())],
            subscriptions: subs, accountsById: accountsById, fxRates: Fx.decimalRates, baseCode: "RUB"
        )
        XCTAssertEqual(rate.monthlySubscriptionCost, 2_249_00)
    }

    /// A $20 Netflix charge on a USD account is recognised as the $20
    /// subscription by the ACCOUNT currency, even with a legacy "RUB" label.
    func test_subscriptionMatch_usesAccountCurrencyNotLabel() {
        let subs = [Fx.sub(20_00, currency: "USD", name: "Netflix")]
        let charge = Fx.tx("n", account: "usd", native: 20_00, type: .expense, label: "RUB", merchant: "NETFLIX.COM")
        let rubCharge = Fx.tx("r", account: "rub", native: 20_00, type: .expense, label: "USD", merchant: "Netflix")
        let kept = CashFlowEngine.filterOutSubscriptionLinked(
            transactions: [charge, rubCharge], subscriptions: subs, calendar: .current,
            accountsById: accountsById, baseCode: "RUB"
        )
        XCTAssertEqual(kept.map(\.id), ["r"], "20 ₽ is not the $20 subscription, whatever its label says")
    }

    private func pdfInput(_ txs: [Transaction], subs: [SubscriptionTracker] = []) -> PDFReportGenerator.Input {
        PDFReportGenerator.Input(
            title: "R", periodLabel: "Nov", generatedAt: Date(), userName: nil, currencyCode: "RUB",
            transactions: txs, previousTransactions: [], categories: [Fx.category("food", name: "Food")],
            accounts: Array(accountsById.values), accountFilter: nil, budgets: [], subscriptions: subs,
            fxRates: Fx.decimalRates
        )
    }

    func test_pdfSections_areInReportCurrency() {
        let input = pdfInput([
            Fx.tx("u", account: "usd", native: 50_00, type: .expense, categoryId: "food"),
            Fx.tx("r", account: "rub", native: 3_000_00, type: .expense, categoryId: "food"),
            Fx.tx("big-rub", account: "rub", native: 4_000_00, type: .expense)
        ], subs: [Fx.sub(20_00, currency: "USD"), Fx.sub(399_00, currency: "RUB")])

        let food = PDFReportGenerator.categoryTotals(input).first { $0.name == "Food" }
        XCTAssertEqual(food?.amountInBase, 7_625_00)
        XCTAssertEqual(food?.count, 2)

        // $50 (4 625 ₽) outranks 4 000 ₽ — it used to sort as "5 000 < 400 000".
        XCTAssertEqual(PDFReportGenerator.topExpenses(input).map(\.tx.id), ["u", "big-rub", "r"])

        let subs = PDFReportGenerator.subscriptionSummary(input)
        XCTAssertEqual(subs.monthlyTotalInBase, 2_249_00)
        XCTAssertEqual(subs.lines.first { $0.currency == "USD" }?.monthly, 20_00, "rows stay in their own currency")
    }

    func test_csv_hasCurrencyColumnAndQuotes() {
        let rows = [
            Fx.tx("u", account: "usd", native: 50_05, type: .expense, categoryId: "food"),
            Fx.tx("r", account: "rub", native: -5, type: .income)
        ]
        var withComma = rows[0]
        withComma.description = "Coffee, \"large\""
        let csv = CSVExporter.export(
            transactions: [withComma, rows[1]],
            categories: [Fx.category("food", name: "Food, drinks")],
            accounts: Array(accountsById.values)
        )
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].split(separator: ",").count, 7, "header has a currency column")
        XCTAssertTrue(lines.contains { $0.contains(",50.05,USD,\"Food, drinks\",\"Coffee, \"\"large\"\"\",usd") }, csv)
        XCTAssertTrue(lines.contains { $0.contains(",-0.05,RUB,") }, csv)
    }

    private static func lastMonthDay() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let d = cal.date(byAdding: .month, value: -1, to: Date())!
        let c = cal.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d-10", c.year!, c.month!)
    }
}
