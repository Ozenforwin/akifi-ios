import XCTest
@testable import AkifiIOS

/// Tests for `UserCurrencyPreferences`.
///
/// Each test constructs a fresh instance backed by a private
/// `UserDefaults(suiteName:)` so production storage is never touched and
/// tests can run in any order without leakage.
@MainActor
final class UserCurrencyPreferencesTests: XCTestCase {

    // MARK: - Helpers

    /// Builds an isolated preferences instance + suite. The suite is
    /// removed before each call so we always start with a clean slate.
    private func makeIsolated(
        suiteName: String = "test.UserCurrencyPreferences.\(UUID().uuidString)"
    ) -> (UserCurrencyPreferences, UserDefaults) {
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        return (UserCurrencyPreferences(defaults: suite), suite)
    }

    // MARK: - Defaults on first launch

    func test_defaultCodes_first_launch_returns_legacy_nine() {
        let (prefs, _) = makeIsolated()
        XCTAssertEqual(
            prefs.activeCodes,
            ["RUB", "USD", "EUR", "VND", "THB", "IDR", "KZT", "GEL", "TRY"],
            "First-launch default must match the pre-migration hard-coded enum so existing users don't see a UX regression."
        )
    }

    func test_defaultCodes_count_is_nine() {
        let (prefs, _) = makeIsolated()
        XCTAssertEqual(prefs.activeCodes.count, 9)
    }

    // MARK: - add / remove / contains

    func test_add_appendsCode() {
        let (prefs, _) = makeIsolated()
        XCTAssertFalse(prefs.contains("GBP"))
        prefs.add("GBP")
        XCTAssertTrue(prefs.contains("GBP"))
        XCTAssertEqual(prefs.activeCodes.last, "GBP")
    }

    func test_add_isCaseInsensitive() {
        let (prefs, _) = makeIsolated()
        prefs.add("gbp")
        XCTAssertTrue(prefs.contains("GBP"))
        XCTAssertTrue(prefs.contains("gbp"))
        XCTAssertEqual(prefs.activeCodes.last, "GBP",
                       "Codes must be normalised to uppercase regardless of input casing.")
    }

    func test_add_doesNotDuplicate() {
        let (prefs, _) = makeIsolated()
        let beforeCount = prefs.activeCodes.count
        prefs.add("USD") // already in the legacy default
        XCTAssertEqual(prefs.activeCodes.count, beforeCount,
                       "Adding an already-active code must be a no-op.")
        prefs.add("usd")
        XCTAssertEqual(prefs.activeCodes.count, beforeCount,
                       "Case-insensitive duplicate must be a no-op.")
    }

    func test_add_unknownCode_isRejected() {
        let (prefs, _) = makeIsolated()
        let before = prefs.activeCodes
        prefs.add("ZZZ")
        prefs.add("XX")
        prefs.add("")
        XCTAssertEqual(prefs.activeCodes, before,
                       "Unknown / non-ISO codes must be silently rejected — Manage UI only ever passes valid codes, this is the belt-and-braces guard.")
    }

    func test_remove_dropsCode() {
        let (prefs, _) = makeIsolated()
        XCTAssertTrue(prefs.contains("USD"))
        prefs.remove("USD")
        XCTAssertFalse(prefs.contains("USD"))
    }

    func test_remove_protectsLastCode() {
        let (prefs, _) = makeIsolated()
        prefs.activeCodes = ["USD"]
        prefs.remove("USD")
        XCTAssertEqual(prefs.activeCodes, ["USD"],
                       "Removing the last remaining code must be a no-op so the picker is never empty.")
    }

    func test_contains_isCaseInsensitive() {
        let (prefs, _) = makeIsolated()
        XCTAssertTrue(prefs.contains("usd"))
        XCTAssertTrue(prefs.contains("USD"))
        XCTAssertTrue(prefs.contains("Usd"))
    }

    // MARK: - Persistence

    func test_persistence_acrossInstances() {
        let suiteName = "test.UserCurrencyPreferences.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)

        let prefs1 = UserCurrencyPreferences(defaults: suite)
        prefs1.activeCodes = ["USD", "EUR", "GBP"]

        // New instance reading the same suite must see the same list.
        let prefs2 = UserCurrencyPreferences(defaults: suite)
        XCTAssertEqual(prefs2.activeCodes, ["USD", "EUR", "GBP"])
    }

    func test_persistence_emptyArray_resetsToDefaults() {
        let (prefs, suite) = makeIsolated()
        prefs.activeCodes = ["USD"]
        prefs.activeCodes = []
        XCTAssertEqual(prefs.activeCodes, UserCurrencyPreferences.defaultCodes,
                       "Setting empty must fall back to defaults.")
        XCTAssertNil(suite.object(forKey: UserCurrencyPreferences.storageKey),
                     "Empty input must clear the storage key, so the next launch reads the default list.")
    }

    // MARK: - activeCurrencies — robustness against broken UserDefaults

    func test_activeCurrencies_skipsUnknownCodes_inStorage() {
        let suiteName = "test.UserCurrencyPreferences.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        // Inject a value that contains both real and bogus codes.
        suite.set("USD,ZZZ,EUR,XX", forKey: UserCurrencyPreferences.storageKey)

        let prefs = UserCurrencyPreferences(defaults: suite)
        // activeCodes preserves the raw list (we don't auto-clean storage),
        // but activeCurrencies skips codes we can't resolve.
        let currencyCodes = prefs.activeCurrencies.map(\.code)
        XCTAssertTrue(currencyCodes.contains("USD"))
        XCTAssertTrue(currencyCodes.contains("EUR"))
        XCTAssertFalse(currencyCodes.contains("ZZZ"))
        XCTAssertFalse(currencyCodes.contains("XX"))
    }

    func test_load_emptyString_fallsBackToDefaults() {
        let suiteName = "test.UserCurrencyPreferences.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        suite.set("", forKey: UserCurrencyPreferences.storageKey)

        let prefs = UserCurrencyPreferences(defaults: suite)
        XCTAssertEqual(prefs.activeCodes, UserCurrencyPreferences.defaultCodes)
    }

    // MARK: - reorder

    func test_reorder_preservesAllCodes() {
        let (prefs, _) = makeIsolated()
        prefs.activeCodes = ["USD", "EUR", "GBP"]
        prefs.reorder(["GBP", "USD", "EUR"])
        XCTAssertEqual(prefs.activeCodes, ["GBP", "USD", "EUR"])
    }

    func test_reorder_withMissingCodes_appendsThem() {
        let (prefs, _) = makeIsolated()
        prefs.activeCodes = ["USD", "EUR", "GBP"]
        // Caller drops one — reorder appends the missing entry rather
        // than silently dropping it.
        prefs.reorder(["GBP", "USD"])
        XCTAssertEqual(prefs.activeCodes, ["GBP", "USD", "EUR"])
    }

    func test_reorder_ignoresExtraneousCodes() {
        let (prefs, _) = makeIsolated()
        prefs.activeCodes = ["USD", "EUR"]
        // "JPY" was never active — must not get added through reorder.
        prefs.reorder(["JPY", "EUR", "USD"])
        XCTAssertEqual(prefs.activeCodes, ["EUR", "USD"])
    }
}
