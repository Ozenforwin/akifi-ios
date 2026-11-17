import XCTest
@testable import AkifiIOS

/// Y11 — the widget must not show yesterday's "today" after midnight — and
/// the snapshot writer's crash on duplicate account ids.
@MainActor
final class SharedSnapshotRolloverTests: XCTestCase {

    private let cal = SharedSnapshot.dayCalendar

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func snapshot(day: String?, updated: Date) -> SharedSnapshot {
        var s = SharedSnapshot(
            schemaVersion: SharedSnapshot.currentSchemaVersion, lastUpdated: updated,
            baseCurrency: "RUB", baseCurrencySymbol: "₽", baseCurrencyDecimals: 0,
            totalBalance: 1_000_00, accountCount: 1,
            dailyLimit: 500_00, dailyLimitBudgetName: "Еда", dailySpentToday: 300_00, dailyLimitUtilization: 40,
            currentStreak: 3, nextMilestone: 7,
            todayIncome: 1_000_00, todayExpense: 300_00, todayNet: 700_00, netWorth: nil
        )
        s.dayKey = day
        s.dailyLimitLeftover = 3_000_00
        s.dailyLimitPeriodEnd = "2026-11-22"
        return s
    }

    func test_sameDay_unchanged() {
        let s = snapshot(day: "2026-11-17", updated: at(2026, 11, 17, 9))
        XCTAssertEqual(s.rolledOver(to: at(2026, 11, 17, 23)), s)
    }

    func test_nextDay_zeroesTodayAndRespreadsLeftover() {
        let s = snapshot(day: "2026-11-17", updated: at(2026, 11, 17, 21))
        let r = s.rolledOver(to: at(2026, 11, 18, 0))
        XCTAssertEqual(r.todayIncome, 0)
        XCTAssertEqual(r.todayExpense, 0)
        XCTAssertEqual(r.todayNet, 0)
        XCTAssertEqual(r.dailySpentToday, 0)
        // 3 000 ₽ over 18…22 Nov (5 days, today included)
        XCTAssertEqual(r.dailyLimit, 600_00)
        XCTAssertEqual(r.dayKey, "2026-11-18")
        XCTAssertEqual(r.totalBalance, s.totalBalance, "non-daily fields untouched")
    }

    func test_legacyPayloadWithoutDayKey_usesLastUpdated() throws {
        let s = snapshot(day: nil, updated: at(2026, 11, 17, 21))
        XCTAssertEqual(s.rolledOver(to: at(2026, 11, 17, 22)), s)
        XCTAssertEqual(s.rolledOver(to: at(2026, 11, 18, 8)).todayExpense, 0)

        // Old JSON without the new keys still decodes.
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        var json = try JSONSerialization.jsonObject(with: enc.encode(SharedSnapshot.placeholder)) as! [String: Any]
        json.removeValue(forKey: "dayKey")
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode(SharedSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.dayKey)
    }

    func test_periodOver_keepsStoredLimit() {
        let s = snapshot(day: "2026-11-17", updated: at(2026, 11, 17))
        XCTAssertEqual(s.rolledOver(to: at(2026, 11, 25)).dailyLimit, 500_00)
    }

    /// `Dictionary(uniqueKeysWithValues:)` trapped when a shared account
    /// came back twice; writing the snapshot must survive it.
    func test_writer_duplicateAccountIds_doesNotCrash() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = DataStore(cache: PersistenceManager(directory: tmp))
        store.isConnectedProvider = { false }
        let account = Account(id: "acc-1", userId: "u1", name: "Семейный", icon: "💳", color: "blue", initialBalance: 0, currency: "rub")
        store.accounts = [account, account]
        let cm = CurrencyManager()
        cm.rates = ["USD": 1, "RUB": 80]
        SharedSnapshotWriter.write(dataStore: store, currencyManager: cm)
    }
}
