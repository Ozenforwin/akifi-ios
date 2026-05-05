import XCTest
@testable import AkifiIOS

/// Regression test for the cross-currency transfer write-path bug
/// reported 2026-05-05 (Olga's "Оля рубли" → "Оля зарубежный" transfer
/// turned 530 USD into a 39 747 $ row that drove the destination
/// balance ~75× too far in the wrong direction).
///
/// Root cause: TransferFormView.save() wrote a single base-currency
/// `amount` to BOTH legs and tagged both with the user's entry
/// currency, violating ADR-001 (`amount_native` must be in the owning
/// account's currency, `currency` must mirror it). The fix splits the
/// derivation into per-leg `LegFields` and writes `foreign_*` only on
/// legs whose account currency differs from the entry currency.
@MainActor
final class TransferFormCrossCurrencyTests: XCTestCase {

    private func currencyManager(rates: [String: Double] = ["USD": 1.0, "RUB": 92.5, "EUR": 0.92]) -> CurrencyManager {
        let cm = CurrencyManager()
        cm.rates = rates
        return cm
    }

    private func account(id: String, currency: String) -> Account {
        Account(
            id: id, userId: "u1", name: "test-\(id)", icon: "💳", color: "#000000",
            initialBalance: 0, currency: currency
        )
    }

    // MARK: - Cross-currency: source-account leg

    func testLegFields_EntryUsd_RubAccount_StoresInRubWithForeignFields() {
        let cm = currencyManager()
        let leg = TransferFormView.legFields(
            amountValue: Decimal(530),
            entryCurrency: .usd,
            account: account(id: "rub", currency: "rub"),
            cm: cm
        )
        // 530 USD * 92.5 RUB/USD = 49 025 RUB (round arithmetic via fixture rates).
        XCTAssertEqual(leg.amountInAccount, Decimal(530) * Decimal(92.5))
        XCTAssertEqual(leg.currencyLabel, "RUB",
                       "currency must mirror the LEG account, not the user's entry currency")
        XCTAssertEqual(leg.foreignAmount, Decimal(530))
        XCTAssertEqual(leg.foreignCurrency, "USD")
        XCTAssertNotNil(leg.fxRate)
        XCTAssertEqual(leg.fxRate, Decimal(92.5))
    }

    // MARK: - Cross-currency: destination leg in entry currency

    func testLegFields_EntryUsd_UsdAccount_StoresVerbatimNoForeign() {
        let cm = currencyManager()
        let leg = TransferFormView.legFields(
            amountValue: Decimal(530),
            entryCurrency: .usd,
            account: account(id: "usd", currency: "usd"),
            cm: cm
        )
        XCTAssertEqual(leg.amountInAccount, Decimal(530))
        XCTAssertEqual(leg.currencyLabel, "USD")
        XCTAssertNil(leg.foreignAmount,
                     "no foreign_* when entry currency matches the leg's account currency")
        XCTAssertNil(leg.foreignCurrency)
        XCTAssertNil(leg.fxRate)
    }

    // MARK: - Same-currency transfer

    func testLegFields_EntryRub_RubAccount_NoForeignFields() {
        let cm = currencyManager()
        let leg = TransferFormView.legFields(
            amountValue: Decimal(1000),
            entryCurrency: .rub,
            account: account(id: "rub", currency: "rub"),
            cm: cm
        )
        XCTAssertEqual(leg.amountInAccount, Decimal(1000))
        XCTAssertEqual(leg.currencyLabel, "RUB")
        XCTAssertNil(leg.foreignAmount)
        XCTAssertNil(leg.foreignCurrency)
        XCTAssertNil(leg.fxRate)
    }

    // MARK: - Triangulated cross-currency (USD entry, RUB → EUR)

    func testLegFields_TriangulatesViaUsdPivot() {
        let cm = currencyManager()
        let eurLeg = TransferFormView.legFields(
            amountValue: Decimal(100),
            entryCurrency: .usd,
            account: account(id: "eur", currency: "eur"),
            cm: cm
        )
        // 100 USD → 92 EUR via the USD pivot table.
        XCTAssertEqual(eurLeg.amountInAccount, Decimal(100) * Decimal(0.92))
        XCTAssertEqual(eurLeg.currencyLabel, "EUR")
        XCTAssertEqual(eurLeg.foreignAmount, Decimal(100))
        XCTAssertEqual(eurLeg.foreignCurrency, "USD")
    }

    // MARK: - FX safeguard: missing rate falls back to identity

    func testCrossConvert_MissingRate_ReturnsAmountUnchanged() {
        let cm = currencyManager(rates: ["USD": 1.0])
        // No rate for RUB → must NOT silently produce a 0-or-nonsense value.
        let result = TransferFormView.crossConvert(
            amount: Decimal(530),
            from: .usd,
            to: .rub,
            using: cm
        )
        XCTAssertEqual(result, Decimal(530),
                       "Missing rate must return input unchanged (ADR-001 / 2026-04-19 incident).")
    }

    // MARK: - Full transfer scenario: Olga's bug repro

    func testOlgaTransfer_RubToUsd_LegsWrittenInOwnCurrencies() {
        let cm = currencyManager()
        let entry = Decimal(530)
        let entryCcy = CurrencyCode.usd
        let rubAcc = account(id: "olya-rub", currency: "rub")
        let usdAcc = account(id: "olya-usd", currency: "usd")

        let fromLeg = TransferFormView.legFields(
            amountValue: entry, entryCurrency: entryCcy, account: rubAcc, cm: cm
        )
        let toLeg = TransferFormView.legFields(
            amountValue: entry, entryCurrency: entryCcy, account: usdAcc, cm: cm
        )

        // Source (RUB) leg: stored in RUB, with USD foreign-entry context.
        XCTAssertEqual(fromLeg.currencyLabel, "RUB")
        XCTAssertEqual(fromLeg.amountInAccount, Decimal(530) * Decimal(92.5))
        XCTAssertEqual(fromLeg.foreignCurrency, "USD")

        // Destination (USD) leg: stored in USD, NO foreign-entry context.
        XCTAssertEqual(toLeg.currencyLabel, "USD")
        XCTAssertEqual(toLeg.amountInAccount, Decimal(530))
        XCTAssertNil(toLeg.foreignCurrency,
                     "Pre-fix: this was 'USD' with amount=39747 (RUB-quantity-tagged-as-USD), " +
                     "which sent the destination balance ~75× the wrong way.")
    }
}
