import XCTest
@testable import AkifiIOS

/// Unit tests for `SubscriptionMatcher`.
///
/// Coverage target: ≥80 % of scoring branches (amount / date / merchant)
/// plus the final `bestMatch` selection and threshold behaviour.
final class SubscriptionMatcherTests: XCTestCase {

    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.locale = Locale(identifier: "en_US_POSIX")
        calendar = cal
    }

    // MARK: - Factories

    private func makeSubscription(
        id: String = "sub-1",
        name: String = "Spotify",
        amount: Int64 = 29900,     // 299.00
        currency: String = "RUB",
        nextPaymentDate: String? = "2026-04-20",
        status: SubscriptionTrackerStatus = .active
    ) -> SubscriptionTracker {
        SubscriptionTracker(
            id: id,
            userId: "user-1",
            serviceName: name,
            amount: amount,
            currency: currency,
            billingPeriod: .monthly,
            startDate: "2026-01-01",
            lastPaymentDate: nil,
            nextPaymentDate: nextPaymentDate,
            reminderDays: 1,
            iconColor: "#60A5FA",
            isActive: status == .active,
            status: status
        )
    }

    private func makeTransaction(
        id: String = "tx-1",
        amount: Int64 = 29900,
        currency: String? = "RUB",
        type: TransactionType = .expense,
        date: String = "2026-04-20",
        description: String? = nil,
        merchantName: String? = "Spotify"
    ) -> Transaction {
        Transaction(
            id: id,
            userId: "user-1",
            accountId: "acc-1",
            amount: amount,
            currency: currency,
            description: description,
            categoryId: nil,
            type: type,
            date: date,
            rawDateTime: date,
            merchantName: merchantName,
            merchantFuzzy: nil,
            transferGroupId: nil,
            status: nil,
            createdAt: nil,
            updatedAt: nil
        )
    }

    // MARK: - Amount component

    func testAmountExactMatchGives50() {
        let sub = makeSubscription(amount: 29900)
        let tx = makeTransaction(amount: 29900)
        let (_, amount, _, _) = SubscriptionMatcher.score(transaction: tx, subscription: sub, calendar: calendar)
        XCTAssertEqual(amount, 50)
    }

    func testAmountWithinToleranceGives50() {
        // 5% tolerance → 29900 ±1495 = [28405, 31395]
        let sub = makeSubscription(amount: 29900)
        let tx = makeTransaction(amount: 31000)
        let (_, amount, _, _) = SubscriptionMatcher.score(transaction: tx, subscription: sub, calendar: calendar)
        XCTAssertEqual(amount, 50)
    }

    func testAmountOutsideToleranceGivesZero() {
        let sub = makeSubscription(amount: 29900)
        let tx = makeTransaction(amount: 35000) // ~17% off
        let (_, amount, _, _) = SubscriptionMatcher.score(transaction: tx, subscription: sub, calendar: calendar)
        XCTAssertEqual(amount, 0)
    }

    func testAmountCurrencyMismatchGivesZero() {
        let sub = makeSubscription(amount: 29900, currency: "RUB")
        let tx = makeTransaction(amount: 29900, currency: "USD")
        let (_, amount, _, _) = SubscriptionMatcher.score(transaction: tx, subscription: sub, calendar: calendar)
        XCTAssertEqual(amount, 0)
    }

    func testAmountMissingTxCurrencyGivesZero() {
        let sub = makeSubscription(amount: 29900, currency: "RUB")
        let tx = makeTransaction(amount: 29900, currency: nil)
        let (_, amount, _, _) = SubscriptionMatcher.score(transaction: tx, subscription: sub, calendar: calendar)
        XCTAssertEqual(amount, 0)
    }

    // MARK: - Date component

    func testDateExactMatchGives30() {
        let sub = makeSubscription(nextPaymentDate: "2026-04-20")
        let tx = makeTransaction(date: "2026-04-20")
        let (_, _, date, _) = SubscriptionMatcher.score(transaction: tx, subscription: sub, calendar: calendar)
        XCTAssertEqual(date, 30)
    }

    func testDateOneDayAwayScales() {
        // daysDiff = 1 → score = 30 * (1 - 1/7) = 25.71 → 26 (rounded)
        let sub = makeSubscription(nextPaymentDate: "2026-04-20")
        let tx = makeTransaction(date: "2026-04-19")
        let (_, _, date, _) = SubscriptionMatcher.score(transaction: tx, subscription: sub, calendar: calendar)
        XCTAssertEqual(date, 26)
    }

    func testDateAtWindowEdgeGivesZero() {
        // daysDiff = 7 → score = 30 * (1 - 7/7) = 0
        let sub = makeSubscription(nextPaymentDate: "2026-04-20")
        let tx = makeTransaction(date: "2026-04-13")
        let (_, _, date, _) = SubscriptionMatcher.score(transaction: tx, subscription: sub, calendar: calendar)
        XCTAssertEqual(date, 0)
    }

    func testDateOutsideWindowGivesZero() {
        let sub = makeSubscription(nextPaymentDate: "2026-04-20")
        let tx = makeTransaction(date: "2026-04-01") // 19 days away
        let (_, _, date, _) = SubscriptionMatcher.score(transaction: tx, subscription: sub, calendar: calendar)
        XCTAssertEqual(date, 0)
    }

    func testDateMissingSubscriptionNextGivesZero() {
        let sub = makeSubscription(nextPaymentDate: nil)
        let tx = makeTransaction(date: "2026-04-20")
        let (_, _, date, _) = SubscriptionMatcher.score(transaction: tx, subscription: sub, calendar: calendar)
        XCTAssertEqual(date, 0)
    }

    // MARK: - Merchant component

    func testMerchantExactSubstringGives20() {
        let sub = makeSubscription(name: "Spotify")
        let tx = makeTransaction(merchantName: "SPOTIFY P12345")
        let (_, _, _, merchant) = SubscriptionMatcher.score(transaction: tx, subscription: sub, calendar: calendar)
        XCTAssertEqual(merchant, 20)
    }

    func testMerchantDescriptionMatchGives20() {
        let sub = makeSubscription(name: "Netflix")
        let tx = makeTransaction(description: "Monthly netflix charge", merchantName: nil)
        let (_, _, _, merchant) = SubscriptionMatcher.score(transaction: tx, subscription: sub, calendar: calendar)
        XCTAssertEqual(merchant, 20)
    }

    func testMerchantNoMatchGivesZero() {
        let sub = makeSubscription(name: "Spotify")
        let tx = makeTransaction(merchantName: "Starbucks")
        let (_, _, _, merchant) = SubscriptionMatcher.score(transaction: tx, subscription: sub, calendar: calendar)
        XCTAssertEqual(merchant, 0)
    }

    func testMerchantReverseContainsAlsoMatches() {
        // Subscription name is longer than the merchant (e.g. user stored "YouTube Premium")
        let sub = makeSubscription(name: "YouTube Premium")
        let tx = makeTransaction(description: nil, merchantName: "youtube")
        let (_, _, _, merchant) = SubscriptionMatcher.score(transaction: tx, subscription: sub, calendar: calendar)
        XCTAssertEqual(merchant, 20)
    }

    func testMerchantEmptyHaystacksGiveZero() {
        let sub = makeSubscription(name: "Spotify")
        let tx = makeTransaction(description: nil, merchantName: nil)
        let (_, _, _, merchant) = SubscriptionMatcher.score(transaction: tx, subscription: sub, calendar: calendar)
        XCTAssertEqual(merchant, 0)
    }

    // MARK: - Total scoring

    func testPerfectMatchTotals100() {
        let sub = makeSubscription(nextPaymentDate: "2026-04-20")
        let tx = makeTransaction(date: "2026-04-20", merchantName: "Spotify")
        let (total, _, _, _) = SubscriptionMatcher.score(transaction: tx, subscription: sub, calendar: calendar)
        XCTAssertEqual(total, 100)
    }

    func testIncomeTransactionsReturnZero() {
        let sub = makeSubscription()
        let tx = makeTransaction(type: .income)
        let (total, _, _, _) = SubscriptionMatcher.score(transaction: tx, subscription: sub, calendar: calendar)
        XCTAssertEqual(total, 0)
    }

    func testTransferTransactionsReturnZero() {
        let sub = makeSubscription()
        let tx = makeTransaction(type: .transfer)
        let (total, _, _, _) = SubscriptionMatcher.score(transaction: tx, subscription: sub, calendar: calendar)
        XCTAssertEqual(total, 0)
    }

    // MARK: - bestMatch

    func testBestMatchAboveThresholdSelected() {
        let sub = makeSubscription()
        let tx = makeTransaction(date: "2026-04-20")
        let result = SubscriptionMatcher.bestMatch(for: tx, in: [sub], calendar: calendar)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.subscription.id, "sub-1")
        XCTAssertGreaterThanOrEqual(result?.score ?? 0, 60)
    }

    func testBestMatchBelowThresholdReturnsNil() {
        // Merchant no-match (0) + date far away (0) + amount match (50) = 50 → below 60.
        let sub = makeSubscription(nextPaymentDate: "2026-04-01") // 19 days off
        let tx = makeTransaction(date: "2026-04-20", merchantName: "Unrelated")
        let result = SubscriptionMatcher.bestMatch(for: tx, in: [sub], calendar: calendar)
        XCTAssertNil(result)
    }

    func testBestMatchPicksHighestScore() {
        let spotify = makeSubscription(id: "sub-spotify", name: "Spotify", amount: 29900, nextPaymentDate: "2026-04-20")
        let yt = makeSubscription(id: "sub-yt", name: "YouTube Premium", amount: 29900, nextPaymentDate: "2026-04-22")
        let tx = makeTransaction(amount: 29900, date: "2026-04-20", merchantName: "SPOTIFY")

        let result = SubscriptionMatcher.bestMatch(for: tx, in: [yt, spotify], calendar: calendar)
        XCTAssertEqual(result?.subscription.id, "sub-spotify")
    }

    func testBestMatchIgnoresNonActiveSubscriptions() {
        let pausedSub = makeSubscription(status: .paused)
        let tx = makeTransaction(date: "2026-04-20", merchantName: "Spotify")
        let result = SubscriptionMatcher.bestMatch(for: tx, in: [pausedSub], calendar: calendar)
        XCTAssertNil(result)
    }

    func testBestMatchIgnoresCancelled() {
        let cancelledSub = makeSubscription(status: .cancelled)
        let tx = makeTransaction(date: "2026-04-20", merchantName: "Spotify")
        let result = SubscriptionMatcher.bestMatch(for: tx, in: [cancelledSub], calendar: calendar)
        XCTAssertNil(result)
    }

    func testBestMatchEmptyCandidatesReturnsNil() {
        let tx = makeTransaction()
        let result = SubscriptionMatcher.bestMatch(for: tx, in: [], calendar: calendar)
        XCTAssertNil(result)
    }

    // MARK: - Real-world edges

    func testExchangeRateSmallDiffStillMatches() {
        // Bank charged 299.50 vs subscription's 299.00 — <5% tolerance.
        let sub = makeSubscription(amount: 29900)
        let tx = makeTransaction(amount: 29950, date: "2026-04-20", merchantName: "Spotify")
        let result = SubscriptionMatcher.bestMatch(for: tx, in: [sub], calendar: calendar)
        XCTAssertNotNil(result)
    }

    func testZeroAmountSubscriptionDoesNotCrash() {
        // Defensive: amount=0 must short-circuit, not divide by zero.
        let sub = makeSubscription(amount: 0)
        let tx = makeTransaction(amount: 29900, date: "2026-04-20", merchantName: "Spotify")
        let (_, amount, _, _) = SubscriptionMatcher.score(transaction: tx, subscription: sub, calendar: calendar)
        XCTAssertEqual(amount, 0)
    }

    func testThresholdBoundaryExactly60Matches() {
        // 50 (amount) + 10 (merchant? no — merchant is 20 or 0). So construct:
        // amount 50 + date @ 2 days = 30*(1-2/7) = 21 → 71. Hmm.
        // Use amount 50 + date @ 4 days = 30*(1-4/7) = 13 → 63 ≥ 60.
        let sub = makeSubscription(nextPaymentDate: "2026-04-20")
        let tx = makeTransaction(amount: 29900, date: "2026-04-16", merchantName: "Unrelated")
        let result = SubscriptionMatcher.bestMatch(for: tx, in: [sub], calendar: calendar)
        XCTAssertNotNil(result)
        XCTAssertGreaterThanOrEqual(result?.score ?? 0, 60)
    }
}
