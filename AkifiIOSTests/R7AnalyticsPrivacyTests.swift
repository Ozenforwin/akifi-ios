import XCTest
@testable import AkifiIOS

/// R7: analytics events carry no amounts or category ids, and the privacy
/// manifest declares what the app actually collects.
final class R7AnalyticsPrivacyTests: XCTestCase {

    private var captured: [(name: String, params: [String: Any]?)] = []
    private var originalSink: ((String, [String: Any]?) -> Void)!

    override func setUp() {
        super.setUp()
        originalSink = AnalyticsService.sink
        AnalyticsService.sink = { [weak self] name, params in
            self?.captured.append((name, params))
        }
    }

    override func tearDown() {
        AnalyticsService.sink = originalSink
        captured = []
        super.tearDown()
    }

    private func keys(_ index: Int) -> Set<String> {
        Set(captured[index].params.map { Array($0.keys) } ?? [])
    }

    func test_R7_addTransaction_sendsTypeOnly() {
        AnalyticsService.logAddTransaction(type: "expense")
        XCTAssertEqual(captured.map(\.name), ["add_transaction"])
        XCTAssertEqual(keys(0), ["type"])
    }

    func test_R7_contribution_sendsTypeOnly() {
        AnalyticsService.logContribution(type: "contribution")
        XCTAssertEqual(keys(0), ["type"])
    }

    /// The allowlist is the guarantee: a future call site that passes an
    /// amount or category through the generic entry point loses it.
    func test_R7_genericEvent_dropsFinancialParameters() {
        AnalyticsService.logEvent("future_event", params: [
            "amount": 1500.0,
            "category": "c0ffee00-0000-0000-0000-000000000000",
            "category_id": "c0ffee00-0000-0000-0000-000000000000",
            "description": "Аптека",
            "balance": 120_000,
            "type": "expense",
        ])
        XCTAssertEqual(keys(0), ["type"])
    }

    func test_R7_eventWithOnlyForbiddenParameters_sendsNoParameters() {
        AnalyticsService.logEvent("future_event", params: ["amount": 10])
        XCTAssertEqual(captured.count, 1)
        XCTAssertNil(captured[0].params)
    }

    func test_R7_magnitudeBucket_hidesTheAmount() {
        XCTAssertEqual(AnalyticsService.magnitudeBucket(0), "0")
        XCTAssertEqual(AnalyticsService.magnitudeBucket(1), "1")
        XCTAssertEqual(AnalyticsService.magnitudeBucket(-1), "1")
        XCTAssertEqual(AnalyticsService.magnitudeBucket(99), "<100")
        XCTAssertEqual(AnalyticsService.magnitudeBucket(100), "<10k")
        XCTAssertEqual(AnalyticsService.magnitudeBucket(3_888_000), "10k+")
        XCTAssertEqual(AnalyticsService.magnitudeBucket(.min), "10k+")
    }

    func test_R7_privacyManifest_declaresWhatTheAppCollects() throws {
        let url = try XCTUnwrap(Bundle(for: AppViewModel.self).url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        )
        let collected = (plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? [])
            .compactMap { $0["NSPrivacyCollectedDataType"] as? String }
        let declared = Set(collected)
        for required in [
            "NSPrivacyCollectedDataTypeOtherFinancialInfo",
            "NSPrivacyCollectedDataTypePhotosorVideos",
            "NSPrivacyCollectedDataTypeAudioData",
            "NSPrivacyCollectedDataTypeOtherUserContent",
            "NSPrivacyCollectedDataTypeCrashData",
            "NSPrivacyCollectedDataTypePerformanceData",
            "NSPrivacyCollectedDataTypeProductInteraction",
        ] {
            XCTAssertTrue(declared.contains(required), required)
        }
        // There is no in-app payment flow — PaymentInfo was a false claim.
        XCTAssertFalse(declared.contains("NSPrivacyCollectedDataTypePaymentInfo"))
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
    }
}
