import XCTest
import UIKit
@testable import AkifiIOS

// Regression tests for the 2026-11-27 review, feature stream
// (deposits, calculators, bank import, net-worth forms, journal, goals,
// subscription history, sharing): V1–V10.

// MARK: - Helpers

private func json(_ value: some Encodable) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func isNull(_ dict: [String: Any], _ key: String) -> Bool {
    dict.keys.contains(key) && dict[key] is NSNull
}

private func note(_ id: String, title: String = "n") -> FinancialNote {
    FinancialNote(id: id, userId: "u1", title: title, content: "c", createdAt: "2026-11-10T10:00:00+00:00")
}

private func account(_ id: String, currency: String = "RUB") -> Account {
    Account(id: id, userId: "u1", name: id, icon: "💳", color: "#000000", initialBalance: 0, currency: currency)
}

// MARK: - V1 deposits

@MainActor
final class V1DepositMaturityTests: XCTestCase {

    private func day(_ s: String) -> Date { DepositsViewModel.parseDate(s)! }

    private func deposit(
        id: String = "d1",
        end: String? = "2026-09-01",
        status: DepositStatus = .active,
        closedAt: String? = nil
    ) -> Deposit {
        Deposit(
            id: id, userId: "u1", accountId: "acc-\(id)",
            interestRate: 16, compoundFrequency: .monthly,
            startDate: "2025-09-01", endDate: end,
            status: status, closedAt: closedAt, returnToAccountId: "acc-main"
        )
    }

    private let lot = DepositContribution(
        id: "c1", depositId: "d1", userId: "u1", amount: 1_000_000_00, contributedAt: "2025-09-01"
    )

    /// 1 M ₽ at 16 %, ended on 1 September, app opened on 1 December:
    /// interest stops at the end date instead of growing ~47 500 ₽ more.
    func test_V1_interestStopsAtTheEndDate() {
        let d = deposit()
        let now = day("2026-12-01")
        XCTAssertEqual(d.accrualCutoff(now: now), day("2026-09-01"))

        let atEnd = InterestCalculator.accrueInterest(contributions: [lot], rate: 16, frequency: .monthly, asOf: day("2026-09-01"))
        let atNow = InterestCalculator.accrueInterest(contributions: [lot], rate: 16, frequency: .monthly, asOf: now)
        let paid = InterestCalculator.accrueInterest(contributions: [lot], rate: 16, frequency: .monthly, asOf: d.accrualCutoff(now: now))
        XCTAssertEqual(paid, atEnd)
        XCTAssertGreaterThan(atNow - atEnd, 40_000_00, "the old asOf: Date() overpaid by tens of thousands")
    }

    func test_V1_cutoff_openEndedIsNow_closedEarlyIsCloseInstant() {
        let now = day("2026-12-01")
        XCTAssertEqual(deposit(end: nil).accrualCutoff(now: now), now)
        XCTAssertEqual(deposit(end: "2027-03-01").accrualCutoff(now: now), now)
        let closed = deposit(end: "2027-03-01", status: .closedEarly, closedAt: "2026-10-15T09:00:00Z")
        XCTAssertEqual(closed.accrualCutoff(now: now), AppDateFormatters.parseTimestamp("2026-10-15T09:00:00Z"))
    }

    func test_V1_liveValuesStopAtTheCutoff() {
        let vm = DepositsViewModel()
        let d = deposit()
        vm.contributionsByDeposit[d.id] = [lot]
        XCTAssertEqual(
            vm.liveAccruedInterest(for: d, asOf: day("2027-06-01")),
            vm.liveAccruedInterest(for: d, asOf: day("2026-09-01"))
        )
        XCTAssertEqual(vm.liveTotalValue(for: d, asOf: day("2027-06-01")), vm.projectedMaturityValue(for: d))
    }

    func test_V1_autoMature_onlyEndedActiveDepositsWithLoadedContributions() {
        let today = day("2026-12-01")
        XCTAssertTrue(DepositsViewModel.shouldAutoMature(deposit(), today: today, contributionsLoaded: true, isClosing: false))
        XCTAssertFalse(DepositsViewModel.shouldAutoMature(deposit(), today: today, contributionsLoaded: false, isClosing: false),
                       "contributions failed to load → never 'matured' without a payout")
        XCTAssertFalse(DepositsViewModel.shouldAutoMature(deposit(), today: today, contributionsLoaded: true, isClosing: true),
                       "a close already in flight (pull-to-refresh during maturity)")
        XCTAssertFalse(DepositsViewModel.shouldAutoMature(deposit(status: .matured), today: today, contributionsLoaded: true, isClosing: false))
        XCTAssertFalse(DepositsViewModel.shouldAutoMature(deposit(end: "2027-01-01"), today: today, contributionsLoaded: true, isClosing: false))
        XCTAssertFalse(DepositsViewModel.shouldAutoMature(deposit(end: nil), today: today, contributionsLoaded: true, isClosing: false))
    }

    func test_V1_inFlightGuard_rejectsASecondClose() async {
        let vm = DepositsViewModel()
        let d = deposit(end: "2027-03-01")
        vm.contributionsByDeposit[d.id] = [lot]
        XCTAssertTrue(vm.beginClosing(d.id))
        XCTAssertFalse(vm.beginClosing(d.id))
        XCTAssertTrue(vm.isClosing(d))

        do {
            try await vm.closeEarly(d, depositAccount: account(d.accountId), returnTo: account("acc-main"), dataStore: DataStore())
            XCTFail("a second close must be rejected")
        } catch {
            XCTAssertEqual(error as? DepositCloseError, .alreadyClosing)
        }
        XCTAssertTrue(vm.isClosing(d), "the rejected call must not release the first call's claim")

        vm.endClosing(d.id)
        XCTAssertFalse(vm.isClosing(d))
        XCTAssertTrue(vm.beginClosing(d.id))
    }

    func test_V1_closeWithoutLoadedContributions_isRefused() async {
        let vm = DepositsViewModel()
        let d = deposit(end: "2027-03-01")
        do {
            try await vm.closeEarly(d, depositAccount: account(d.accountId), returnTo: account("acc-main"), dataStore: DataStore())
            XCTFail("closing with unknown principal would pay out nothing")
        } catch {
            XCTAssertEqual(error as? DepositCloseError, .contributionsNotLoaded)
        }
        XCTAssertFalse(vm.isClosing(d), "the claim is released on every exit")
    }

    func test_V1_payoutIds_areStablePerDepositAndDistinct() {
        let a = DepositsViewModel.payoutIds(depositId: "d1")
        XCTAssertEqual(a, DepositsViewModel.payoutIds(depositId: "d1"), "a retry writes the same ids")
        XCTAssertNotEqual(a, DepositsViewModel.payoutIds(depositId: "d2"))
        XCTAssertEqual(Set([a.interest, a.returnOut, a.returnIn, a.transferGroup]).count, 4)
        for id in [a.interest, a.returnOut, a.returnIn, a.transferGroup] {
            XCTAssertNotNil(UUID(uuidString: id))
        }
    }

    func test_V1_reopenPayload_clearsClosedAt() throws {
        let body = try json(ReopenDepositInput())
        XCTAssertEqual(body["status"] as? String, "active")
        XCTAssertTrue(isNull(body, "closed_at"))
    }
}

// MARK: - V2 calculators

final class V2CalculatorOverflowTests: XCTestCase {

    /// 7 000 % for 40 years overflowed Decimal into NaN; `Int64(NaN)` crashed.
    func test_V2_rate7000Percent_doesNotCrash_andSaturates() {
        let r = CompoundProjector.project(principal: 100_000_00, monthlyContribution: 10_000_00, annualReturn: 70, years: 40)
        XCTAssertEqual(r.points.count, 41)
        XCTAssertEqual(r.finalValue, Int64.max)
        XCTAssertTrue(zip(r.points, r.points.dropFirst()).allSatisfy { $0.value <= $1.value })
        XCTAssertGreaterThan(r.totalInterest, 0)
    }

    func test_V2_ratePercentIsClampedTo0_100() {
        XCTAssertEqual(CompoundProjector.annualReturn(fromPercent: 7_000), 1)
        XCTAssertEqual(CompoundProjector.annualReturn(fromPercent: 100), 1)
        XCTAssertEqual(CompoundProjector.annualReturn(fromPercent: 7), Decimal(string: "0.07"))
        XCTAssertEqual(CompoundProjector.annualReturn(fromPercent: -5), 0)
        XCTAssertEqual(CompoundProjector.annualReturn(fromPercent: .nan), 0)
        // The clamped maximum is still safe at the longest horizon.
        let r = CompoundProjector.project(principal: 1_000_000_00, monthlyContribution: 100_000_00,
                                          annualReturn: CompoundProjector.annualReturn(fromPercent: 7_000), years: 50)
        XCTAssertEqual(r.finalValue, Int64.max)
    }

    func test_V2_clampToInt64_NaNSaturatesInBothCopies() {
        XCTAssertEqual(CompoundProjector.clampToInt64(.nan), Int64.max)
        XCTAssertEqual(FIREProjector.clampToInt64(.nan), Int64.max)
        XCTAssertEqual(CompoundProjector.clampToInt64(Decimal(string: "1e30")!), Int64.max)
        XCTAssertEqual(FIREProjector.clampToInt64(Decimal(string: "1e30")!), Int64.max)
        XCTAssertEqual(CompoundProjector.clampToInt64(12_345), 12_345)
    }

    func test_V2_hugeContributions_saturateInsteadOfTrapping() {
        let r = CompoundProjector.project(principal: Int64.max / 2, monthlyContribution: Int64.max / 4, annualReturn: 0, years: 40)
        XCTAssertEqual(r.totalContributions, Int64.max)
    }
}

// MARK: - V3 bank import

final class V3BankImportIdempotencyTests: XCTestCase {

    private func row(_ date: String, _ amount: Double, _ description: String, type: String = "expense") -> ParsedTransaction {
        let body: [String: Any] = [
            "date": date, "amount": amount, "description": description, "type": type, "is_duplicate": false
        ]
        let data = try! JSONSerialization.data(withJSONObject: body)
        return try! JSONDecoder().decode(ParsedTransaction.self, from: data)
    }

    func test_V3_rowIds_areDeterministic_soARetryCantDuplicate() {
        let rows = [row("2026-11-10", 150, "Coffee"), row("2026-11-10", 1234.56, "Groceries"), row("2026-11-11", 150, "Coffee")]
        let first = BankImportView.importRowIds(for: rows, accountId: "acc1")
        XCTAssertEqual(first, BankImportView.importRowIds(for: rows, accountId: "acc1"))
        XCTAssertEqual(Set(first).count, 3)
        XCTAssertTrue(first.allSatisfy { UUID(uuidString: $0) != nil })
        XCTAssertNotEqual(first, BankImportView.importRowIds(for: rows, accountId: "acc2"), "another account → other rows")
    }

    /// Two genuine identical purchases on one day stay two rows.
    func test_V3_identicalRows_getDistinctIdsByOrdinal() {
        let rows = [row("2026-11-10", 150, "Coffee"), row("2026-11-10", 150, "Coffee")]
        let ids = BankImportView.importRowIds(for: rows, accountId: "acc1")
        XCTAssertNotEqual(ids[0], ids[1])
        // Same statement parsed again → same two ids.
        XCTAssertEqual(ids, BankImportView.importRowIds(for: rows, accountId: "acc1"))
    }

    func test_V3_amountAndTypeArePartOfTheIdentity() {
        let a = BankImportView.importRowIds(for: [row("2026-11-10", 150, "X")], accountId: "a")
        let b = BankImportView.importRowIds(for: [row("2026-11-10", 150.01, "X")], accountId: "a")
        let c = BankImportView.importRowIds(for: [row("2026-11-10", 150, "X", type: "income")], accountId: "a")
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func test_V3_deterministicUUID_isAVersion5UUID() {
        let id = DeterministicUUID.make("a", "b")
        XCTAssertEqual(id, DeterministicUUID.make("a", "b"))
        XCTAssertNotEqual(id, DeterministicUUID.make("ab"), "parts are separated")
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(Array(id)[14], "5")
        XCTAssertTrue("89ab".contains(Array(id)[19]))
        XCTAssertEqual(id, id.lowercased())
    }
}

// MARK: - V4 cleared fields

final class V4ExplicitNullTests: XCTestCase {

    func test_V4_liability_clearedFieldsAreNull_untouchedFieldsOmitted() throws {
        let original: Int64? = nil
        let rate: Double? = nil
        let notes = ""
        let input = UpdateLiabilityInput(
            name: "Loan", category: "loan", current_balance: 100_00,
            original_amount: .some(original), interest_rate: .some(rate),
            currency: "RUB", icon: nil, color: nil,
            notes: .some(notes.isEmpty ? nil : notes),
            monthly_payment: .some(nil), end_date: .some(nil)
        )
        let body = try json(input)
        for key in ["original_amount", "interest_rate", "notes", "monthly_payment", "end_date"] {
            XCTAssertTrue(isNull(body, key), "\(key) must be written as NULL")
        }
        XCTAssertNil(body["icon"], "icon is not edited by the form — left alone")
        XCTAssertNil(body["color"])
        XCTAssertEqual(body["name"] as? String, "Loan")

        let untouched = try json(UpdateLiabilityInput(
            name: nil, category: nil, current_balance: nil, original_amount: nil, interest_rate: nil,
            currency: nil, icon: nil, color: nil, notes: nil, monthly_payment: nil, end_date: nil
        ))
        XCTAssertTrue(untouched.isEmpty, "`.none` leaves every column alone")
    }

    func test_V4_liability_setValuesAreWritten() throws {
        let body = try json(UpdateLiabilityInput(
            name: nil, category: nil, current_balance: nil, original_amount: .some(5_00), interest_rate: .some(7.5),
            currency: nil, icon: nil, color: nil, notes: .some("x"), monthly_payment: .some(1_00), end_date: .some("2027-01-01")
        ))
        XCTAssertEqual(body["original_amount"] as? Int, 500)
        XCTAssertEqual(body["interest_rate"] as? Double, 7.5)
        XCTAssertEqual(body["end_date"] as? String, "2027-01-01")
    }

    func test_V4_asset_holding_noteMood_clearToNull() throws {
        let asset = try json(UpdateAssetInput(name: "A", category: nil, current_value: nil, currency: nil,
                                              icon: nil, color: nil, notes: .some(nil), acquired_date: .some(nil)))
        XCTAssertTrue(isNull(asset, "notes"))
        XCTAssertTrue(isNull(asset, "acquired_date"))
        XCTAssertNil(asset["icon"])

        let holding = try json(UpdateHoldingInput(ticker: "VOO", notes: .some(nil)))
        XCTAssertTrue(isNull(holding, "notes"))
        XCTAssertNil(try json(UpdateHoldingInput(lastPrice: 1))["notes"], "a price-only update leaves the note alone")

        let mood = try json(UpdateNoteInput(content: "c", mood: .some(nil)))
        XCTAssertTrue(isNull(mood, "mood"))
        XCTAssertNil(try json(UpdateNoteInput(content: "c"))["mood"])
        XCTAssertEqual(try json(UpdateNoteInput(mood: .some("good")))["mood"] as? String, "good")
    }
}

// MARK: - V5 image downscale

final class V5ImageDownscaleTests: XCTestCase {

    private func image(width: CGFloat, height: CGFloat, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// The old renderer ran at the screen scale: a "shrunk" photo came out
    /// larger than the original. The result is now `maxEdge` PIXELS.
    func test_V5_downscaled_isMeasuredInPixels() throws {
        let photo = image(width: 4032, height: 3024, scale: 1)
        let out = photo.downscaled(toMaxEdge: 1600)
        let cg = try XCTUnwrap(out.cgImage)
        XCTAssertEqual(cg.width, 1600)
        XCTAssertEqual(cg.height, 1200)
        XCTAssertEqual(out.scale, 1)
    }

    func test_V5_retinaSource_isMeasuredInPixelsToo() throws {
        let shot = image(width: 1000, height: 500, scale: 3)   // 3000×1500 px
        let cg = try XCTUnwrap(shot.downscaled(toMaxEdge: 1800).cgImage)
        XCTAssertEqual(cg.width, 1800)
        XCTAssertEqual(cg.height, 900)
    }

    func test_V5_smallImage_isReturnedUnchanged() {
        let small = image(width: 300, height: 200, scale: 1)
        XCTAssertTrue(small.downscaled(toMaxEdge: 400) === small)
    }
}

// MARK: - V6 journal search

@MainActor
final class V6JournalSearchTests: XCTestCase {

    func test_V6_ilikeValue_isQuotedAndEscaped() {
        typealias R = FinancialNoteRepository
        XCTAssertEqual(R.ilikeContainsValue("кофе"), "\"%кофе%\"")
        // A comma / parentheses no longer split the or=(…) tree.
        XCTAssertEqual(R.ilikeContainsValue("кофе, (латте)"), "\"%кофе, (латте)%\"")
        // LIKE wildcards are literal; inside the quotes `\` is doubled.
        XCTAssertEqual(R.ilikeContainsValue("50%"), "\"%50\\\\%%\"")
        XCTAssertEqual(R.ilikeContainsValue("a_b"), "\"%a\\\\_b%\"")
        XCTAssertEqual(R.ilikeContainsValue("a\"b"), "\"%a\\\"b%\"")
        XCTAssertEqual(R.ilikeContainsValue("a\\b"), "\"%a\\\\\\\\b%\"")
        // PostgREST maps `*` to `%`; it becomes a one-character wildcard.
        XCTAssertEqual(R.ilikeContainsValue("a*b"), "\"%a_b%\"")
    }

    /// Search used to replace the feed: after clearing it, only the matches
    /// were left and paging continued from the old cursor.
    func test_V6_searchKeepsTheFeed_andClearingRestoresIt() async {
        let match = note("n2", title: "кофе")
        let vm = JournalViewModel(searchNotes: { _ in [match] }, searchDebounce: .zero)
        vm.notes = [note("n1"), match, note("n3")]

        vm.updateSearch("кофе")
        await vm.searchTask?.value
        XCTAssertEqual(vm.filteredNotes.map(\.id), ["n2"])
        XCTAssertEqual(vm.notes.count, 3, "the feed is untouched")
        XCTAssertFalse(vm.canLoadMore, "no feed paging under search results")

        vm.updateSearch("")
        XCTAssertNil(vm.searchResults)
        XCTAssertEqual(vm.filteredNotes.map(\.id), ["n1", "n2", "n3"])
        XCTAssertTrue(vm.canLoadMore)
    }

    /// Fast typing: the answer for "к" arrives after the one for "кофе".
    func test_V6_staleResponse_isDropped() async throws {
        let slow = note("slow"), fast = note("fast")
        let vm = JournalViewModel(searchNotes: { query in
            if query == "к" {
                try? await Task.sleep(for: .milliseconds(200))   // returns early when cancelled
                return [slow]
            }
            return [fast]
        }, searchDebounce: .zero)

        vm.updateSearch("к")
        let first = vm.searchTask
        try await Task.sleep(for: .milliseconds(20))   // the first request is in flight
        vm.updateSearch("кофе")
        await vm.searchTask?.value
        await first?.value
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(vm.filteredNotes.map(\.id), ["fast"])
    }

    func test_V6_debounce_onlyTheLastQueryIsSent() async throws {
        let sent = SentQueries()
        let vm = JournalViewModel(searchNotes: { query in
            await sent.append(query)
            return []
        }, searchDebounce: .milliseconds(50))
        for q in ["к", "ко", "коф", "кофе"] { vm.updateSearch(q) }
        await vm.searchTask?.value
        let queries = await sent.all
        XCTAssertEqual(queries, ["кофе"])
    }
}

private actor SentQueries {
    private(set) var all: [String] = []
    func append(_ q: String) { all.append(q) }
}

// MARK: - V7 goals

@MainActor
final class V7GoalInputTests: XCTestCase {

    func test_V7_decimalInput_acceptsTheDecimalComma() {
        XCTAssertEqual(DecimalInput.parse("1500,75"), Decimal(string: "1500.75"))
        XCTAssertEqual(DecimalInput.parse("0,5"), Decimal(string: "0.5"))
        XCTAssertEqual(DecimalInput.parse("1500.75"), Decimal(string: "1500.75"))
        XCTAssertEqual(DecimalInput.parse("1 234,56"), Decimal(string: "1234.56"))
        XCTAssertEqual(DecimalInput.parse("1\u{00A0}234,56"), Decimal(string: "1234.56"))
        XCTAssertEqual(DecimalInput.parse("1.234,56"), Decimal(string: "1234.56"))
        XCTAssertEqual(DecimalInput.parse("1,234.56"), Decimal(string: "1234.56"))
        XCTAssertEqual(DecimalInput.parse("1.500.000"), 1_500_000)
        XCTAssertEqual(DecimalInput.parse(",5"), Decimal(string: "0.5"))
        XCTAssertEqual(DecimalInput.parse("5,"), 5)
    }

    func test_V7_decimalInput_rejectsInsteadOfReturningAPrefix() {
        for bad in ["", " ", "abc", "12abc", "1,2,3.4.5", "-5", "1e5", "٣"] {
            XCTAssertNil(DecimalInput.parse(bad), bad)
        }
    }

    func test_V7_kopecks() {
        XCTAssertEqual(DecimalInput.kopecks("1500,75"), 150_075)
        XCTAssertEqual(DecimalInput.kopecks("0,5"), 50)
        XCTAssertEqual(DecimalInput.kopecks("0,005"), 1, "ties away from zero (MoneyRounding)")
        XCTAssertNil(DecimalInput.kopecks("x"))
    }

    func test_V7_createGoalPayload_carriesTheInterestFields() throws {
        let body = try json(CreateSavingsGoalInput(
            user_id: "u1", name: "Car", icon: "🚗", color: "#000000", target_amount: 1_500_75,
            deadline: nil, account_id: nil, reminder_enabled: false, priority: 0,
            interest_rate: Decimal(string: "7.5")!, interest_type: "monthly", interest_compound: false
        ))
        XCTAssertEqual(body["interest_rate"] as? Double, 7.5)
        XCTAssertEqual(body["interest_type"] as? String, "monthly")
        XCTAssertEqual(body["interest_compound"] as? Bool, false)
        XCTAssertEqual(SavingsViewModel.GoalInterest.noInterest, SavingsViewModel.GoalInterest(rate: 0, type: "annual", compound: true))
    }

    func test_V7_zeroContribution_isRefused() async {
        let vm = SavingsViewModel()
        do {
            try await vm.addContribution(goalId: "g1", amount: 0, type: .contribution, note: nil)
            XCTFail("a zero contribution must not be saved")
        } catch {
            XCTAssertEqual(error as? SavingsInputError, .amountNotPositive)
        }
    }
}

// MARK: - V8 subscription payment deletion

final class V8SubscriptionPaymentDeletionTests: XCTestCase {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func sub(last: String?, next: String?) -> SubscriptionTracker {
        SubscriptionTracker(
            id: "s1", userId: "u1", serviceName: "Netflix", amount: 999_00, currency: "RUB",
            billingPeriod: .monthly, startDate: "2026-01-17", lastPaymentDate: last, nextPaymentDate: next
        )
    }

    private func after(deleting deleted: [String], remaining: [String], _ s: SubscriptionTracker) -> (last: String?, next: String?) {
        SubscriptionDateEngine.datesAfterDeleting(paymentDates: deleted, remainingPaymentDates: remaining, subscription: s, calendar: cal)
    }

    /// A mistaken payment on 10 Nov settled the 17 Nov charge and moved
    /// `next` to 17 Dec; deleting it brings the November charge back.
    func test_V8_deletingAMistakenPayment_restoresTheCharge() {
        let r = after(deleting: ["2026-11-10"], remaining: ["2026-10-17", "2026-09-17"], sub(last: "2026-11-10", next: "2026-12-17"))
        XCTAssertEqual(r.last, "2026-10-17")
        XCTAssertEqual(r.next, "2026-11-17")
    }

    func test_V8_deletingTheOnlyPayment_serverTimestamp() {
        let r = after(deleting: ["2026-11-17T00:00:00+00:00"], remaining: [], sub(last: "2026-11-17", next: "2026-12-17"))
        XCTAssertNil(r.last)
        XCTAssertEqual(r.next, "2026-11-17")
    }

    func test_V8_deletingAnOldPayment_changesNothing() {
        let s = sub(last: "2026-11-17", next: "2026-12-17")
        let r = after(deleting: ["2026-03-17"], remaining: ["2026-10-17", "2026-11-17"], s)
        XCTAssertEqual(r.last, "2026-11-17")
        XCTAssertEqual(r.next, "2026-12-17")
    }

    /// Two payments for the same cycle: deleting one keeps it paid.
    func test_V8_deletingADuplicate_keepsTheCyclePaid() {
        let r = after(deleting: ["2026-11-18"], remaining: ["2026-11-17"], sub(last: "2026-11-18", next: "2026-12-17"))
        XCTAssertEqual(r.last, "2026-11-17")
        XCTAssertEqual(r.next, "2026-12-17")
    }

    /// Only the deleted payment's own cycle re-opens — not older gaps.
    func test_V8_onlyTheDeletedCycleReopens() {
        let r = after(deleting: ["2026-11-17"], remaining: ["2026-09-17"], sub(last: "2026-11-17", next: "2026-12-17"))
        XCTAssertEqual(r.next, "2026-11-17", "October has no row but wasn't settled by the deleted payment")
    }

    func test_V8_deletionNeverAdvancesNext_andKeepsAFormEnteredLast() {
        let r = after(deleting: ["2026-11-17"], remaining: [], sub(last: "2026-11-20", next: "2026-10-17"))
        XCTAssertEqual(r.next, "2026-10-17")
        XCTAssertEqual(r.last, "2026-11-20", "no deleted payment explains this date")
    }

    func test_V8_datesPayload_writesNullLast() throws {
        let body = try json(UpdateSubscriptionDatesInput(last_payment_date: nil, next_payment_date: "2026-11-17"))
        XCTAssertTrue(isNull(body, "last_payment_date"))
        XCTAssertEqual(body["next_payment_date"] as? String, "2026-11-17")
    }
}

// MARK: - V9 small ones

@MainActor
final class V9SmallFixesTests: XCTestCase {

    /// The quote key is the device-zone day; the transaction day must go
    /// in as local midnight. UTC midnight was yesterday in UTC− zones.
    func test_V9_reconciliationQuoteDay_isTheLocalDay() {
        let local = CurrencyReconciliationView.quoteDay(forTransactionDate: "2026-11-17")!
        XCTAssertEqual(ExchangeRateService.historicalDateKey(for: local), "2026-11-17")
        XCTAssertEqual(CurrencyReconciliationView.quoteDay(forTransactionDate: "2026-11-17T10:00:00Z"), local)

        // What the old UTC parse produced for a UTC−5 user.
        let utcMidnight = AppDateFormatters.utcDate.date(from: "2026-11-17")!
        XCTAssertEqual(ExchangeRateService.historicalDateKey(for: utcMidnight, timeZone: TimeZone(secondsFromGMT: -5 * 3600)!), "2026-11-16")
    }

    func test_V9_fallbackRate_neverGuesses() {
        let rates: [String: Double] = ["USD": 1, "RUB": 92.5]
        XCTAssertEqual(CurrencyReconciliationView.fallbackRate(from: "USD", to: "RUB", rates: rates), Decimal(92.5))
        XCTAssertNil(CurrencyReconciliationView.fallbackRate(from: "EUR", to: "RUB", rates: rates), "was ?? 1.0 → 92.5, not 1:1, slipped past the guard")
        XCTAssertNil(CurrencyReconciliationView.fallbackRate(from: "RUB", to: "EUR", rates: rates))
        XCTAssertNil(CurrencyReconciliationView.fallbackRate(from: "RUB", to: "USD", rates: ["USD": 1, "RUB": 0]))
        XCTAssertEqual(CurrencyReconciliationView.fallbackRate(from: "rub", to: "RUB", rates: [:]), 1)
    }

    func test_V9_chartSnapshots_inTheCurrentBaseCurrency() {
        let rates: [String: Decimal] = ["USD": 1, "RUB": Decimal(string: "92.5")!]
        let rubSnap = NetWorthSnapshot(id: "s1", userId: "u1", snapshotDate: "2026-11-01", accountsTotal: 0,
                                       assetsTotal: 0, liabilitiesTotal: 0, netWorth: 9_250_000_00, currency: "RUB")
        let usdSnap = NetWorthSnapshot(id: "s2", userId: "u1", snapshotDate: "2026-11-02", accountsTotal: 0,
                                       assetsTotal: 0, liabilitiesTotal: 0, netWorth: 100_000_00, currency: "USD")
        XCTAssertEqual(NetWorthViewModel.chartNetWorth(of: rubSnap, baseCurrency: "USD", rates: rates), 100_000_00,
                       "not a 99 % drop after switching ₽ → $")
        XCTAssertEqual(NetWorthViewModel.chartNetWorth(of: usdSnap, baseCurrency: "USD", rates: rates), 100_000_00)
        XCTAssertNil(NetWorthViewModel.chartNetWorth(of: rubSnap, baseCurrency: "EUR", rates: rates), "no rate → no point, not 1:1")
    }

    /// The first banner's timer must not dismiss the second match.
    func test_V9_expiringBanner_clearsOnlyItsOwnMatch() {
        let store = DataStore()
        let first = DataStore.PendingAutoMatch(subscriptionId: "s1", subscriptionName: "A", paymentId: "p1",
                                               previousLastPaymentDate: nil, previousNextPaymentDate: nil)
        let second = DataStore.PendingAutoMatch(subscriptionId: "s2", subscriptionName: "B", paymentId: "p2",
                                                previousLastPaymentDate: nil, previousNextPaymentDate: nil)
        store.pendingAutoMatch = second
        store.clearPendingAutoMatch(id: first.id)
        XCTAssertEqual(store.pendingAutoMatch, second)
        store.clearPendingAutoMatch(id: second.id)
        XCTAssertNil(store.pendingAutoMatch)
    }
}

// MARK: - V10 split weights

final class V10SplitEditorOwnerTests: XCTestCase {

    private let members = [
        AccountMember(id: "m1", accountId: "a1", userId: "owner", role: .owner),
        AccountMember(id: "m2", accountId: "a1", userId: "partner", role: .editor),
        AccountMember(id: "m3", accountId: "a1", userId: "viewer", role: .viewer)
    ]

    /// Mirrors `is_account_owner`: UPDATE on account_members is owner-only.
    func test_V10_onlyTheOwnerGetsTheEditor() {
        XCTAssertTrue(ShareAccountView.isOwner(viewerId: "owner", members: members))
        XCTAssertFalse(ShareAccountView.isOwner(viewerId: "partner", members: members))
        XCTAssertFalse(ShareAccountView.isOwner(viewerId: "viewer", members: members))
        XCTAssertFalse(ShareAccountView.isOwner(viewerId: "stranger", members: members))
        XCTAssertFalse(ShareAccountView.isOwner(viewerId: nil, members: members))
    }
}
