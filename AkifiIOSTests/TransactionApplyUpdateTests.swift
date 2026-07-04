import XCTest
@testable import AkifiIOS

/// `Transaction.applying(_:)` mirrors the server's UPDATE semantics onto a
/// local row for offline edits: patch non-nil fields, except
/// `replaceCurrencyFields` which takes the currency block verbatim
/// (nil clears — matching the JSON-null UPDATE).
@MainActor
final class TransactionApplyUpdateTests: XCTestCase {

    private func makeTx(
        amountNative: Int64 = 10_000_00,
        foreignAmount: Decimal? = nil,
        foreignCurrency: String? = nil,
        fxRate: Decimal? = nil
    ) -> Transaction {
        Transaction(
            id: "tx-1",
            userId: "u1",
            accountId: "acc-1",
            amount: amountNative,
            amountNative: amountNative,
            currency: "RUB",
            foreignAmount: foreignAmount,
            foreignCurrency: foreignCurrency,
            fxRate: fxRate,
            description: "Кофе",
            categoryId: "cat-1",
            type: .expense,
            date: "2026-07-01",
            rawDateTime: "2026-07-01T10:30:00+00:00",
            merchantName: "Старбакс",
            merchantFuzzy: nil,
            transferGroupId: nil,
            status: nil,
            createdAt: "2026-07-01T10:30:00+00:00",
            updatedAt: nil
        )
    }

    func test_patchMode_overwritesOnlyProvidedFields() {
        let tx = makeTx()

        let updated = tx.applying(UpdateTransactionInput(description: "Обед"))

        XCTAssertEqual(updated.description, "Обед")
        XCTAssertEqual(updated.amountNative, 10_000_00, "amount untouched by a description-only patch")
        XCTAssertEqual(updated.categoryId, "cat-1")
        XCTAssertEqual(updated.merchantName, "Старбакс")
        XCTAssertEqual(updated.status, "pending", "offline-edited rows must show the sync indicator")
    }

    func test_amountNative_convertsToKopecksWithRounding() {
        let tx = makeTx()

        let updated = tx.applying(UpdateTransactionInput(amount: 123.45, amount_native: 123.45))

        XCTAssertEqual(updated.amountNative, 123_45)
    }

    func test_fractionalFxProduct_roundsPlain() {
        let tx = makeTx()

        // 33.333… style FX products must round, not truncate.
        let updated = tx.applying(UpdateTransactionInput(amount_native: Decimal(string: "99.999")!))

        XCTAssertEqual(updated.amountNative, 100_00)
    }

    func test_replaceCurrencyFields_clearsForeignBlock() {
        let tx = makeTx(foreignAmount: 100, foreignCurrency: "USD", fxRate: 90)

        let updated = tx.applying(UpdateTransactionInput(
            amount: 8_500,
            amount_native: 8_500,
            replaceCurrencyFields: true
        ))

        XCTAssertEqual(updated.amountNative, 8_500_00)
        XCTAssertNil(updated.foreignAmount, "replace-mode clears the foreign block when nil is sent")
        XCTAssertNil(updated.foreignCurrency)
        XCTAssertNil(updated.fxRate)
    }

    func test_patchMode_keepsForeignBlock() {
        let tx = makeTx(foreignAmount: 100, foreignCurrency: "USD", fxRate: 90)

        let updated = tx.applying(UpdateTransactionInput(description: "Такси"))

        XCTAssertEqual(updated.foreignAmount, 100, "patch-mode must not clear foreign fields")
        XCTAssertEqual(updated.foreignCurrency, "USD")
        XCTAssertEqual(updated.fxRate, 90)
    }

    func test_dateUpdate_splitsDateAndRawDateTime() {
        let tx = makeTx()

        let updated = tx.applying(UpdateTransactionInput(date: "2026-07-04T18:00:00+00:00"))

        XCTAssertEqual(updated.date, "2026-07-04", "filter date is the yyyy-MM-dd prefix")
        XCTAssertEqual(updated.rawDateTime, "2026-07-04T18:00:00+00:00")
    }

    func test_identityFields_survive() {
        let tx = makeTx()

        let updated = tx.applying(UpdateTransactionInput(amount: 1, amount_native: 1))

        XCTAssertEqual(updated.id, tx.id)
        XCTAssertEqual(updated.userId, tx.userId)
        XCTAssertEqual(updated.createdAt, tx.createdAt)
    }
}
