import XCTest
@testable import AkifiIOS

/// Verifies the App-Group-bound `SharedSnapshot` JSON contract the widget
/// extension depends on. These tests are deliberately trivial — the snapshot
/// is a data class with no logic — but locking the round-trip down prevents
/// accidental schema drift without a version bump.
final class SharedSnapshotTests: XCTestCase {

    func test_placeholder_roundTrip_preservesAllFields() throws {
        let original = SharedSnapshot.placeholder
        let data = try JSONEncoder.widgetTest.encode(original)
        let decoded = try JSONDecoder.widgetTest.decode(SharedSnapshot.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_custom_roundTrip_preservesAllFields() throws {
        let snapshot = SharedSnapshot(
            schemaVersion: SharedSnapshot.currentSchemaVersion,
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_000),
            baseCurrency: "USD",
            baseCurrencySymbol: "$",
            baseCurrencyDecimals: 2,
            totalBalance: 987_654_32,
            accountCount: 5,
            dailyLimit: 42_00,
            dailyLimitBudgetName: "Groceries",
            dailySpentToday: 10_50,
            dailyLimitUtilization: 75,
            currentStreak: 27,
            nextMilestone: 30,
            todayIncome: 100_00,
            todayExpense: 35_00,
            todayNet: 65_00,
            netWorth: 500_000_00
        )
        let data = try JSONEncoder.widgetTest.encode(snapshot)
        let decoded = try JSONDecoder.widgetTest.decode(SharedSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.dailyLimitBudgetName, "Groceries")
        XCTAssertEqual(decoded.netWorth, 500_000_00)
        XCTAssertEqual(decoded.schemaVersion, SharedSnapshot.currentSchemaVersion)
    }

    func test_schemaVersion_mismatch_isDetectableAfterDecode() throws {
        // Simulate a payload written by a "newer" schema.
        let futureJSON = """
        {
          "schemaVersion": 9999,
          "lastUpdated": "2030-01-01T00:00:00Z",
          "baseCurrency": "RUB",
          "baseCurrencySymbol": "₽",
          "baseCurrencyDecimals": 0,
          "totalBalance": 0,
          "accountCount": 0,
          "dailyLimit": null,
          "dailyLimitBudgetName": null,
          "dailySpentToday": 0,
          "dailyLimitUtilization": 0,
          "currentStreak": 0,
          "nextMilestone": 7,
          "todayIncome": 0,
          "todayExpense": 0,
          "todayNet": 0,
          "netWorth": null
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder.widgetTest.decode(SharedSnapshot.self, from: futureJSON)
        // The wire format still decodes successfully (forward compatibility at
        // the JSON level), but the store layer must reject on schema check.
        XCTAssertNotEqual(decoded.schemaVersion, SharedSnapshot.currentSchemaVersion)
    }

    func test_optionalFields_nilRoundTrip() throws {
        let snapshot = SharedSnapshot(
            schemaVersion: SharedSnapshot.currentSchemaVersion,
            lastUpdated: Date(timeIntervalSince1970: 0),
            baseCurrency: "EUR",
            baseCurrencySymbol: "€",
            baseCurrencyDecimals: 2,
            totalBalance: 0,
            accountCount: 0,
            dailyLimit: nil,
            dailyLimitBudgetName: nil,
            dailySpentToday: 0,
            dailyLimitUtilization: 0,
            currentStreak: 0,
            nextMilestone: 7,
            todayIncome: 0,
            todayExpense: 0,
            todayNet: 0,
            netWorth: nil
        )
        let data = try JSONEncoder.widgetTest.encode(snapshot)
        let decoded = try JSONDecoder.widgetTest.decode(SharedSnapshot.self, from: data)
        XCTAssertNil(decoded.dailyLimit)
        XCTAssertNil(decoded.dailyLimitBudgetName)
        XCTAssertNil(decoded.netWorth)
        XCTAssertEqual(decoded, snapshot)
    }
}

// MARK: - Test helpers

private extension JSONEncoder {
    static let widgetTest: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let widgetTest: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
