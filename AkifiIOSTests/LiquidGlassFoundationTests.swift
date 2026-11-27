import XCTest
@testable import AkifiIOS

/// 1.6 Liquid Glass foundation: the availability mapping of `Glass.swift`,
/// the tab shell's routing (system `TabView`, Assistant as the trailing
/// tab, the floating «+») and the spotlight tour's "no step points at
/// nothing" guarantee.
final class LiquidGlassFoundationTests: XCTestCase {

    // MARK: - Glass rendering mode

    func test_rendering_liquidGlassFromIOS26_materialBefore() {
        XCTAssertEqual(AkifiGlassRendering.resolve(operatingSystemMajorVersion: 18), .material)
        XCTAssertEqual(AkifiGlassRendering.resolve(operatingSystemMajorVersion: 25), .material)
        XCTAssertEqual(AkifiGlassRendering.resolve(operatingSystemMajorVersion: 26), .liquidGlass)
        XCTAssertEqual(AkifiGlassRendering.resolve(operatingSystemMajorVersion: 27), .liquidGlass)
    }

    func test_rendering_currentFollowsTheRunningOS() {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        XCTAssertEqual(AkifiGlassRendering.current, AkifiGlassRendering.resolve(operatingSystemMajorVersion: major))
        // The compiler-side check must agree with the pure one.
        if #available(iOS 26.0, *) {
            XCTAssertEqual(AkifiGlassRendering.current, .liquidGlass)
        } else {
            XCTAssertEqual(AkifiGlassRendering.current, .material)
        }
    }

    // MARK: - Button styles

    func test_buttonStyles_mapToGlassOn26AndBorderedBefore() {
        XCTAssertEqual(AkifiButtonStyle.systemStyle(for: .primary, rendering: .liquidGlass), .glassProminent)
        XCTAssertEqual(AkifiButtonStyle.systemStyle(for: .secondary, rendering: .liquidGlass), .glass)
        XCTAssertEqual(AkifiButtonStyle.systemStyle(for: .primary, rendering: .material), .borderedProminent)
        XCTAssertEqual(AkifiButtonStyle.systemStyle(for: .secondary, rendering: .material), .bordered)
    }

    func test_buttonStyles_shorthandsAreThePrimaryAndSecondaryKinds() {
        XCTAssertEqual(AkifiButtonStyle.primary.kind, .primary)
        XCTAssertEqual(AkifiButtonStyle.secondary.kind, .secondary)
        XCTAssertEqual(AkifiButtonStyle.akifiPrimary.kind, .primary)
        XCTAssertEqual(AkifiButtonStyle.akifiSecondary.kind, .secondary)
    }

    // MARK: - Cards (content, not glass)

    func test_cardStyle_cornerRadiiFollowTheDesignRules() {
        XCTAssertEqual(CardStyle.Size.regular.cornerRadius, 20)
        XCTAssertEqual(CardStyle.Size.compact.cornerRadius, 12)
        XCTAssertEqual(CardStyle.Size.regular.defaultPadding, 16)
        XCTAssertEqual(CardStyle.Size.compact.defaultPadding, 12)
    }

    // MARK: - Floating «+» placement

    func test_addButton_sitsTheGapAboveTheMeasuredTabBar() {
        // iPhone 17 Pro, iOS 26.5: 874 pt screen, tab bar region from 791.
        XCTAssertEqual(AkifiChrome.floatingButtonBottomInset(tabBarTop: 791, screenMaxY: 874, gap: 12), 95)
    }

    func test_addButton_fallsBackWhenTheMeasurementIsMissingOrImplausible() {
        let fallback = AkifiChrome.estimatedTabBarRegionHeight + 12
        XCTAssertEqual(AkifiChrome.floatingButtonBottomInset(tabBarTop: nil, screenMaxY: 874, gap: 12), fallback)
        // A hidden tab laid out without the bar reports the screen bottom —
        // the button must not drop onto the tab bar.
        XCTAssertEqual(AkifiChrome.floatingButtonBottomInset(tabBarTop: 874, screenMaxY: 874, gap: 12), fallback)
        XCTAssertEqual(AkifiChrome.floatingButtonBottomInset(tabBarTop: 900, screenMaxY: 874, gap: 12), fallback)
        XCTAssertEqual(AkifiChrome.floatingButtonBottomInset(tabBarTop: 0, screenMaxY: 874, gap: 12), fallback)
    }

    func test_addButton_trailingInsetPerRendering() {
        XCTAssertEqual(AkifiChrome.floatingButtonTrailingInset(for: .liquidGlass), 21)
        XCTAssertEqual(AkifiChrome.floatingButtonTrailingInset(for: .material), 16)
    }

    func test_addButton_hiddenOnAssistantAndWhileTyping() {
        for tab in AppTab.barTabs {
            XCTAssertTrue(AppTab.showsAddButton(on: tab, keyboardVisible: false), "\(tab)")
            XCTAssertFalse(AppTab.showsAddButton(on: tab, keyboardVisible: true), "\(tab)")
        }
        XCTAssertFalse(AppTab.showsAddButton(on: .assistant, keyboardVisible: false))
        XCTAssertFalse(AppTab.showsAddButton(on: .assistant, keyboardVisible: true))
    }

    // MARK: - Tab bar

    func test_tabBar_orderAndTrailingAssistant() {
        XCTAssertEqual(AppTab.barTabs, [.home, .transactions, .analytics, .budgets])
        XCTAssertEqual(AppTab.tabBarTabs, [.home, .transactions, .analytics, .budgets, .assistant])
    }

    func test_tabBar_journalStaysOutOfTheBar() {
        XCTAssertFalse(AppTab.journal.isInTabBar)
        XCTAssertEqual(AppTab.journal.resolvedForTabBar, .home)
        for tab in AppTab.tabBarTabs {
            XCTAssertEqual(tab.resolvedForTabBar, tab)
        }
    }

    func test_tabBar_rawValuesOfExistingTabsUnchanged() {
        XCTAssertEqual(AppTab.home.rawValue, 0)
        XCTAssertEqual(AppTab.transactions.rawValue, 1)
        XCTAssertEqual(AppTab.analytics.rawValue, 2)
        XCTAssertEqual(AppTab.journal.rawValue, 3)
        XCTAssertEqual(AppTab.budgets.rawValue, 4)
    }

    func test_tabBar_screenNamesForAnalytics() {
        // The screen-view event names the pre-1.6 tabs sent must not change.
        XCTAssertEqual(AppTab.home.screenName, "Home")
        XCTAssertEqual(AppTab.transactions.screenName, "Transactions")
        XCTAssertEqual(AppTab.analytics.screenName, "Analytics")
        XCTAssertEqual(AppTab.budgets.screenName, "Budgets")
        XCTAssertEqual(AppTab.journal.screenName, "Journal")
        XCTAssertEqual(AppTab.assistant.screenName, "Assistant")
    }

    func test_tabBar_outlineSymbolsTheSystemFills() {
        XCTAssertEqual(AppTab.home.systemImage, "house")
        XCTAssertEqual(AppTab.transactions.systemImage, "arrow.left.arrow.right")
        XCTAssertEqual(AppTab.analytics.systemImage, "chart.bar")
        XCTAssertEqual(AppTab.budgets.systemImage, "wallet.bifold")
        XCTAssertEqual(AppTab.assistant.systemImage, "sparkles")
        for tab in AppTab.allCases {
            XCTAssertFalse(tab.systemImage.hasSuffix(".fill"), "\(tab)")
            XCTAssertFalse(tab.title.isEmpty, "\(tab)")
        }
    }

    // MARK: - Programmatic tab switches

    func test_pushTargets_mapToTheSameTabsAsBefore() {
        XCTAssertEqual(AppTab(pushTarget: "home"), .home)
        XCTAssertEqual(AppTab(pushTarget: "transactions"), .transactions)
        XCTAssertEqual(AppTab(pushTarget: "budget"), .budgets)
        XCTAssertEqual(AppTab(pushTarget: "budgets"), .budgets)
        XCTAssertEqual(AppTab(pushTarget: "analytics"), .analytics)
        XCTAssertNil(AppTab(pushTarget: "journal"))
        XCTAssertNil(AppTab(pushTarget: "assistant"))
        XCTAssertNil(AppTab(pushTarget: ""))
    }

    func test_widgetDeepLinks_allLandOnTabBarTabs() {
        for host in ["home", "transactions", "analytics", "budgets"] {
            guard case .tab(let tab)? = DeepLink.parse(URL(string: "akifi://\(host)")!) else {
                return XCTFail("akifi://\(host) is not a tab link")
            }
            XCTAssertTrue(tab.isInTabBar, host)
            XCTAssertNotEqual(tab, .assistant, host)
        }
    }

    func test_assistantNavigation_routesAsBefore() {
        XCTAssertEqual(AssistantRoute(.transactions(categoryFilter: "x", merchantFilter: nil, highlightTxIds: nil)),
                       .selectTab(.transactions))
        XCTAssertEqual(AssistantRoute(.budgets), .selectTab(.budgets))
        XCTAssertEqual(AssistantRoute(.savings), .selectTab(.budgets))
        XCTAssertEqual(AssistantRoute(.journal), .none)
        XCTAssertEqual(AssistantRoute(.addExpense), .addExpense)
        XCTAssertEqual(AssistantRoute(.addIncome), .addIncome)
    }

    // MARK: - Profile toolbar button

    func test_profileButton_displayNameFallbacks() {
        XCTAssertEqual(ProfileAvatarButton.displayName(fullName: "Анна", email: "a@b.c"), "Анна")
        XCTAssertEqual(ProfileAvatarButton.displayName(fullName: "", email: "anna@example.com"), "anna")
        XCTAssertEqual(ProfileAvatarButton.displayName(fullName: nil, email: nil), "User")
    }
}

// MARK: - Spotlight tour

@MainActor
final class SpotlightTourTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "SpotlightTourTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makeManager() -> SpotlightManager {
        SpotlightManager(defaults: defaults)
    }

    func test_steps_eachOnABarTab_noDuplicates_noAssistantStep() {
        let steps = SpotlightStep.allSteps
        XCTAssertEqual(Set(steps.map(\.target)).count, steps.count)
        for step in steps {
            XCTAssertTrue(AppTab.barTabs.contains(step.tab), "\(step.target) on \(step.tab)")
        }
        XCTAssertFalse(SpotlightTarget.allCases.map(\.rawValue).contains("aiButton"))
    }

    /// Every step's target is anchored somewhere in the app's views.
    func test_steps_everyTargetIsAnchoredInTheSources() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AkifiIOS", isDirectory: true)
        guard let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            throw XCTSkip("sources not readable from the test host")
        }
        var code = ""
        for case let file as URL in files where file.pathExtension == "swift" {
            code += (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        }
        try XCTSkipIf(code.isEmpty, "sources not readable from the test host")
        for step in SpotlightStep.allSteps {
            let pattern = #"\.spotlight\([^)\n]*\."# + step.target.rawValue + #"\b"#
            XCTAssertNotNil(code.range(of: pattern, options: .regularExpression),
                            "no .spotlight(.\(step.target.rawValue)) anchor")
        }
    }

    func test_anchor_reportAndWithdrawRespectTheOwner() {
        let manager = makeManager()
        let old = UUID(), new = UUID()
        let frame = CGRect(x: 10, y: 20, width: 100, height: 50)
        manager.report(.fabButton, frame: frame, owner: old)
        manager.report(.fabButton, frame: frame.offsetBy(dx: 0, dy: 5), owner: new)
        // The replaced view disappearing must not remove its successor's frame.
        manager.withdraw(.fabButton, owner: old)
        XCTAssertEqual(manager.frames[.fabButton], frame.offsetBy(dx: 0, dy: 5))
        manager.withdraw(.fabButton, owner: new)
        XCTAssertNil(manager.frames[.fabButton])
    }

    func test_currentFrame_ignoresEmptyFrames() {
        let manager = makeManager()
        manager.start()
        let target = SpotlightStep.allSteps[0].target
        manager.report(target, frame: CGRect(x: 0, y: 0, width: 0, height: 40), owner: UUID())
        XCTAssertNil(manager.currentFrame)
        manager.report(target, frame: CGRect(x: 0, y: 0, width: 40, height: 40), owner: UUID())
        XCTAssertNotNil(manager.currentFrame)
    }

    func test_unanchoredStepIsSkipped_anchoredStepStays() {
        let manager = makeManager()
        manager.start()
        XCTAssertEqual(manager.currentStepIndex, 0)

        manager.report(manager.steps[0].target, frame: CGRect(x: 0, y: 0, width: 40, height: 40), owner: UUID())
        manager.skipStepIfUnanchored()
        XCTAssertEqual(manager.currentStepIndex, 0, "a visible target keeps its step")

        manager.next()
        manager.skipStepIfUnanchored()
        XCTAssertEqual(manager.currentStepIndex, 2, "a step with nothing on screen is skipped")
    }

    func test_skippingTheLastUnanchoredStepFinishesTheTour() {
        let manager = makeManager()
        manager.start()
        manager.currentStepIndex = manager.totalSteps - 1
        manager.skipStepIfUnanchored()
        XCTAssertFalse(manager.isActive)
        XCTAssertTrue(defaults.bool(forKey: SpotlightManager.completedKey))
    }

    func test_completedTourDoesNotRestart() {
        let manager = makeManager()
        manager.start()
        manager.skip()
        manager.start()
        XCTAssertFalse(manager.isActive)
        manager.reset()
        manager.start()
        XCTAssertTrue(manager.isActive)
    }

    func test_inactiveTourNeverSkips() {
        let manager = makeManager()
        manager.skipStepIfUnanchored()
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(manager.currentStepIndex, 0)
        XCTAssertFalse(defaults.bool(forKey: SpotlightManager.completedKey))
    }
}
