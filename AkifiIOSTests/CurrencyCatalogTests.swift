import XCTest
@testable import AkifiIOS

/// Tests for the new ISO-backed `Currency` value object and
/// `CurrencyCatalog` namespace. Pins down:
///   - case-insensitive lookup behaviour (`byCode`),
///   - failure path for unknown / empty codes,
///   - search by code AND localized name,
///   - per-currency `decimals` from overrides + Apple defaults,
///   - per-currency `symbol` from overrides + en_US fallback,
///   - JSON round-trip as a single string (matches the old enum's
///     wire format — DO NOT regress to object encoding),
///   - `popular` list sanity (every entry must be in the catalog),
///   - catalog has at least 150 entries (sanity check on
///     `Locale.commonISOCurrencyCodes`).
final class CurrencyCatalogTests: XCTestCase {

    // MARK: - byCode

    func test_byCode_returnsUppercaseCanonical() {
        XCTAssertEqual(CurrencyCatalog.byCode("USD")?.code, "USD")
    }

    func test_byCode_isCaseInsensitive() {
        XCTAssertEqual(CurrencyCatalog.byCode("usd")?.code, "USD")
        XCTAssertEqual(CurrencyCatalog.byCode("UsD")?.code, "USD")
    }

    func test_byCode_unknownReturnsNil() {
        XCTAssertNil(CurrencyCatalog.byCode("ZZZ"))
        XCTAssertNil(CurrencyCatalog.byCode("XX"))
    }

    func test_byCode_emptyReturnsNil() {
        XCTAssertNil(CurrencyCatalog.byCode(""))
    }

    // MARK: - search

    func test_search_byPartialName_findsUSD() {
        let results = CurrencyCatalog.search("dollar")
        let codes = results.map(\.code)
        XCTAssertTrue(codes.contains("USD"),
                      "Search for 'dollar' should include USD; got: \(codes)")
    }

    func test_search_byCodePrefix_findsByCode() {
        let results = CurrencyCatalog.search("usd")
        XCTAssertTrue(results.contains(where: { $0.code == "USD" }))
    }

    func test_search_emptyQueryReturnsAll() {
        let results = CurrencyCatalog.search("")
        XCTAssertEqual(results.count, CurrencyCatalog.all.count)
    }

    // MARK: - decimals

    func test_decimals_overrides_RUB_isZero() {
        XCTAssertEqual(Currency.rub.decimals, 0)
    }

    func test_decimals_overrides_KZT_isZero() {
        XCTAssertEqual(Currency.kzt.decimals, 0)
    }

    func test_decimals_overrides_VND_isZero() {
        XCTAssertEqual(Currency.vnd.decimals, 0)
    }

    func test_decimals_USD_isTwo() {
        XCTAssertEqual(Currency.usd.decimals, 2)
    }

    func test_decimals_EUR_isTwo() {
        XCTAssertEqual(Currency.eur.decimals, 2)
    }

    // MARK: - symbol

    func test_symbol_RUB_fromOverride() {
        XCTAssertEqual(Currency.rub.symbol, "₽",
                       "RUB symbol must come from CurrencyOverrides.json — Apple defaults are inconsistent across locales.")
    }

    func test_symbol_VND_fromOverride() {
        XCTAssertEqual(Currency.vnd.symbol, "₫")
    }

    func test_symbol_KZT_fromOverride() {
        XCTAssertEqual(Currency.kzt.symbol, "₸")
    }

    func test_symbol_USD_isDollarSign() {
        // From en_US locale fallback — should be "$" not "USD".
        XCTAssertEqual(Currency.usd.symbol, "$")
    }

    // MARK: - Codable round-trip

    func test_jsonEncoding_isSingleString() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(Currency.usd)
        let str = String(data: data, encoding: .utf8)
        XCTAssertEqual(str, "\"USD\"",
                       "Currency must encode as a single JSON string to match the on-wire format used by transactions.currency: TEXT.")
    }

    func test_jsonRoundTrip_preservesCode() throws {
        let original = Currency.eur
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Currency.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_jsonDecoding_uppercasesLowercaseInput() throws {
        let data = "\"usd\"".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Currency.self, from: data)
        XCTAssertEqual(decoded.code, "USD")
    }

    // MARK: - popular & all

    func test_popular_allEntriesAreKnown() {
        XCTAssertTrue(CurrencyCatalog.popular.allSatisfy {
            CurrencyCatalog.isKnown($0.code)
        })
    }

    func test_popular_isNotEmpty() {
        XCTAssertGreaterThanOrEqual(CurrencyCatalog.popular.count, 9)
    }

    func test_all_hasOver150Entries() {
        XCTAssertGreaterThanOrEqual(
            CurrencyCatalog.all.count, 150,
            "Locale.commonISOCurrencyCodes should expose >= 150 active ISO codes."
        )
    }

    func test_all_isSortedByCode() {
        let codes = CurrencyCatalog.all.map(\.code)
        XCTAssertEqual(codes, codes.sorted(),
                       "Catalog must be sorted ASC by ISO code for stable picker UX.")
    }

    // MARK: - isKnown

    func test_isKnown_acceptsLowercase() {
        XCTAssertTrue(CurrencyCatalog.isKnown("usd"))
    }

    func test_isKnown_rejectsGarbage() {
        XCTAssertFalse(CurrencyCatalog.isKnown("ZZZ"))
        XCTAssertFalse(CurrencyCatalog.isKnown(""))
    }

    // MARK: - Currency init validation

    func test_currencyInit_validCode() {
        XCTAssertNotNil(Currency(code: "USD"))
        XCTAssertNotNil(Currency(code: "usd"))
    }

    func test_currencyInit_invalidCodeReturnsNil() {
        XCTAssertNil(Currency(code: "ZZZ"))
        XCTAssertNil(Currency(code: ""))
    }
}
