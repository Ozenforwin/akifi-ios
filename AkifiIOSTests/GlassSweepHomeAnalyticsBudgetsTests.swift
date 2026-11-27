import XCTest
import SwiftUI
@testable import AkifiIOS

/// 1.6 Liquid Glass sweep of Home, Analytics, Reports and Budgets: the
/// small pieces of logic the restyle introduced, plus a source guard that
/// keeps the old chrome (opaque bars, materials, shadows, gradients,
/// fixed point sizes, tab-bar spacers) from creeping back into these
/// screens.
final class GlassSweepHomeAnalyticsBudgetsTests: XCTestCase {

    // MARK: - Home: recent transactions list height

    func test_recentList_height_usesMeasuredRowsPlusInsets() {
        let height = RecentTransactionsView.listHeight(
            rowIds: ["a", "b"],
            measured: ["a": 70, "b": 110],
            estimate: 80,
            verticalInset: 4
        )
        XCTAssertEqual(height, 70 + 8 + 110 + 8)
    }

    func test_recentList_height_fallsBackToEstimateForUnmeasuredRows() {
        let height = RecentTransactionsView.listHeight(
            rowIds: ["a", "b", "c"],
            measured: ["b": 120],
            estimate: 80,
            verticalInset: 4
        )
        XCTAssertEqual(height, (80 + 8) + (120 + 8) + (80 + 8))
    }

    func test_recentList_height_ignoresRowsNoLongerShown() {
        // A stale measurement (row scrolled out of the latest 10) must not
        // make the list taller.
        let height = RecentTransactionsView.listHeight(
            rowIds: ["a"],
            measured: ["a": 90, "gone": 500],
            estimate: 80,
            verticalInset: 4
        )
        XCTAssertEqual(height, 98)
    }

    func test_recentList_height_emptyIsZero_andDefaultsMatchTheView() {
        XCTAssertEqual(RecentTransactionsView.listHeight(rowIds: [], measured: [:]), 0)
        // Large Dynamic Type rows are taller than the old fixed 88 pt slot;
        // the measured height wins.
        let tall = RecentTransactionsView.listHeight(rowIds: ["x"], measured: ["x": 180])
        XCTAssertEqual(tall, 180 + 2 * RecentTransactionsView.rowVerticalInset)
        XCTAssertGreaterThan(tall, 88)
    }

    // MARK: - Analytics: account scope in the toolbar

    func test_accountScopeTitle_allWhenNothingSelected() {
        XCTAssertEqual(
            AnalyticsAccountFilterMenu.scopeTitle(selectedAccountId: nil, accounts: DemoData.accounts, allTitle: "All"),
            "All"
        )
    }

    func test_accountScopeTitle_namesTheSelectedAccount() {
        XCTAssertEqual(
            AnalyticsAccountFilterMenu.scopeTitle(selectedAccountId: "demo-acc-2", accounts: DemoData.accounts, allTitle: "All"),
            "Savings"
        )
    }

    func test_accountScopeTitle_staleSelectionReadsAsAll() {
        // The account was deleted / the user left the shared account: the
        // label must not name an account that filters nothing.
        XCTAssertEqual(
            AnalyticsAccountFilterMenu.scopeTitle(selectedAccountId: "gone", accounts: DemoData.accounts, allTitle: "All"),
            "All"
        )
    }

    func test_periodPicker_offersEveryPeriodInOrder() {
        XCTAssertEqual(WidgetPeriod.allCases, [.day, .week, .month, .threeMonths, .year])
    }

    // MARK: - Analytics: change badge semantics

    func test_changeBadge_incomeUpIsGood_expenseUpIsBad() {
        XCTAssertEqual(MonthlySummaryView.changeBadgeColor(change: 12, isIncome: true), Color.income)
        XCTAssertEqual(MonthlySummaryView.changeBadgeColor(change: -12, isIncome: true), Color.expense)
        XCTAssertEqual(MonthlySummaryView.changeBadgeColor(change: 12, isIncome: false), Color.expense)
        XCTAssertEqual(MonthlySummaryView.changeBadgeColor(change: -12, isIncome: false), Color.income)
    }

    func test_changeBadge_zeroChangeKeepsThePreviousMapping() {
        // Before the restyle: income 0 % → green, expenses 0 % → red.
        XCTAssertEqual(MonthlySummaryView.changeBadgeColor(change: 0, isIncome: true), Color.income)
        XCTAssertEqual(MonthlySummaryView.changeBadgeColor(change: 0, isIncome: false), Color.expense)
    }

    // MARK: - Home: streak tiers

    func test_streakTier_thresholds() {
        XCTAssertNil(StreakBadgeView.tierColorHex(for: 1))
        XCTAssertNil(StreakBadgeView.tierColorHex(for: 2))
        XCTAssertEqual(StreakBadgeView.tierColorHex(for: 3), "#FBBF24")
        XCTAssertEqual(StreakBadgeView.tierColorHex(for: 6), "#FBBF24")
        XCTAssertEqual(StreakBadgeView.tierColorHex(for: 7), "#F59E0B")
        XCTAssertEqual(StreakBadgeView.tierColorHex(for: 14), "#F97316")
        XCTAssertEqual(StreakBadgeView.tierColorHex(for: 29), "#F97316")
        XCTAssertEqual(StreakBadgeView.tierColorHex(for: 30), "#8B5CF6")
        XCTAssertEqual(StreakBadgeView.tierColorHex(for: 365), "#8B5CF6")
    }

    // MARK: - Source guard

    /// The swept screens stay on the 1.6 rules (`.claude/design/liquid-glass.md`):
    /// no opaque bars or hidden toolbar backgrounds, no materials or shadows
    /// on content, no decorative gradients, no custom drag indicators, no
    /// fixed point sizes, no leftover spacers for the old tab bar.
    func test_sweptScreens_haveNoLegacyChrome() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AkifiIOS/Views", isDirectory: true)
        let folders = ["Home", "Analytics", "Reports", "Budgets"]
        // Owned by another 1.6 stream.
        let excluded: Set<String> = ["AccountFormView.swift"]

        let forbidden: [(pattern: String, why: String)] = [
            (#"\.background\(\.bar\)"#, "opaque sticky bar"),
            (#"\.toolbarBackground\("#, "custom toolbar background"),
            (#"\.presentationBackground\("#, "custom sheet background"),
            (#"\.presentationDragIndicator\("#, "custom drag indicator"),
            (#"(ultraThin|thin|regular|thick)Material"#, "material on content"),
            (#"\.shadow\("#, "shadow on content"),
            (#"LinearGradient|RadialGradient|\.gradient\b"#, "decorative gradient"),
            (#"\.system\(size:"#, "fixed point size"),
            (#"\.padding\(\.bottom,\s*1[0-9]{2}\)"#, "old tab-bar spacer"),
            (#"Color\.clear\.frame\(height:\s*1[0-9]{2}\)"#, "old tab-bar spacer"),
        ]

        var scanned = 0
        for folder in folders {
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasSuffix(".swift") && !excluded.contains(name) {
                let code = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                scanned += 1
                for rule in forbidden {
                    XCTAssertNil(
                        code.range(of: rule.pattern, options: .regularExpression),
                        "\(folder)/\(name): \(rule.why) (\(rule.pattern))"
                    )
                }
            }
        }
        try XCTSkipIf(scanned == 0, "sources not readable from the test host")
        XCTAssertGreaterThanOrEqual(scanned, 20)
    }
}
