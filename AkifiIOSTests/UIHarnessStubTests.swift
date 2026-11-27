#if DEBUG
import XCTest
@testable import AkifiIOS

/// The screenshot harness answers Supabase from fixtures (1.6 glass
/// sweep). These pin the PostgREST behaviour `SupabasePaging` relies on —
/// a stub that got the count or the paging wrong would make the harness
/// show truncated or empty screens — and that every fixture decodes into
/// the app's models with the right units.
final class UIHarnessStubTests: XCTestCase {

    private func supabaseURL(_ pathAndQuery: String) throws -> URL {
        guard let base = URL(string: AppConstants.supabaseURL), base.host != nil else {
            throw XCTSkip("No Supabase URL configured in this build")
        }
        return try XCTUnwrap(URL(string: base.absoluteString + pathAndQuery))
    }

    private func get(_ pathAndQuery: String, accept: String? = nil) throws -> UIHarnessFixtures.Reply {
        var request = URLRequest(url: try supabaseURL(pathAndQuery))
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        return UIHarnessFixtures.reply(to: request)
    }

    private func rows(_ reply: UIHarnessFixtures.Reply) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: reply.body) as? [[String: Any]])
    }

    // MARK: - Routing

    func test_stub_interceptsOnlyTheSupabaseHost() throws {
        XCTAssertTrue(UIHarnessStubProtocol.canInit(with: URLRequest(url: try supabaseURL("/rest/v1/deposits"))))
        XCTAssertFalse(UIHarnessStubProtocol.canInit(with: URLRequest(url: URL(string: "https://example.com/rest/v1/deposits")!)))
    }

    func test_stub_nonRestEndpointsFail_writesAndRpcSucceedEmpty() throws {
        let function = UIHarnessFixtures.reply(to: URLRequest(url: try supabaseURL("/functions/v1/analyze-receipt")))
        XCTAssertEqual(function.status, 503)

        var write = URLRequest(url: try supabaseURL("/rest/v1/savings_goals"))
        write.httpMethod = "POST"
        let written = UIHarnessFixtures.reply(to: write)
        XCTAssertEqual(written.status, 200)
        XCTAssertEqual(try rows(written).count, 0)

        let rpc = try get("/rest/v1/rpc/get_budget_metrics")
        XCTAssertEqual(rpc.status, 200)
        XCTAssertEqual(try rows(rpc).count, 0)
    }

    func test_stub_unknownTableIsEmptyWithZeroCount() throws {
        let reply = try get("/rest/v1/transactions?select=*&offset=0&limit=1000")
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(try rows(reply).count, 0)
        XCTAssertEqual(reply.headers["Content-Range"], "*/0")
    }

    // MARK: - PostgREST paging

    func test_stub_listCarriesTheTotalCountForSupabasePaging() throws {
        let reply = try get("/rest/v1/savings_goals?select=*&offset=0&limit=1000")
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(try rows(reply).count, 3)
        XCTAssertEqual(reply.headers["Content-Range"], "0-2/3")
    }

    func test_stub_honoursOffsetAndLimit() throws {
        let second = try get("/rest/v1/achievements?offset=2&limit=3")
        XCTAssertEqual(try rows(second).map { $0["id"] as? String }, ["ach-3", "ach-4", "ach-5"])
        XCTAssertEqual(second.headers["Content-Range"], "2-4/9")

        let pastEnd = try get("/rest/v1/achievements?offset=9&limit=1000")
        XCTAssertEqual(try rows(pastEnd).count, 0)
        XCTAssertEqual(pastEnd.headers["Content-Range"], "*/9")
    }

    func test_stub_appliesEqFilters() throws {
        let reply = try get("/rest/v1/savings_contributions?select=*&goal_id=eq.goal-1&order=created_at.desc")
        let found = try rows(reply)
        XCTAssertEqual(found.count, 3)
        XCTAssertTrue(found.allSatisfy { $0["goal_id"] as? String == "goal-1" })
        XCTAssertEqual(reply.headers["Content-Range"], "0-2/3")
    }

    func test_stub_singleObjectRequests() throws {
        let one = try get("/rest/v1/deposits?id=eq.deposit-1", accept: "application/vnd.pgrst.object+json")
        XCTAssertEqual(one.status, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: one.body) as? [String: Any])
        XCTAssertEqual(object["id"] as? String, "deposit-1")

        let none = try get("/rest/v1/deposits?id=eq.missing", accept: "application/vnd.pgrst.object+json")
        XCTAssertEqual(none.status, 406)
    }

    // MARK: - Fixtures decode with the right units

    func test_fixtures_decodeIntoAppModels() {
        let goals = UIHarnessFixtures.decode(SavingsGoal.self, table: "savings_goals")
        XCTAssertEqual(goals.count, 3)
        // Goal amounts are main units in the table, kopecks in the model.
        XCTAssertEqual(goals.first?.targetAmount, 300_000_00)
        XCTAssertEqual(goals.filter { $0.status == .completed }.count, 1)

        XCTAssertEqual(UIHarnessFixtures.decode(SavingsContribution.self, table: "savings_contributions").count, 4)

        let deposits = UIHarnessFixtures.decode(Deposit.self, table: "deposits")
        XCTAssertEqual(deposits.map(\.status), [.active, .matured])
        // Deposit contributions are bigint minor units already.
        let lots = UIHarnessFixtures.decode(DepositContribution.self, table: "deposit_contributions")
        XCTAssertEqual(lots.first?.amount, 300_000_00)

        let challenges = UIHarnessFixtures.decode(SavingsChallenge.self, table: "savings_challenges")
        XCTAssertEqual(challenges.map(\.type), [.noCafe, .weeklyAmount, .categoryLimit])
        XCTAssertEqual(challenges[1].targetAmount, 20_000_00)

        XCTAssertEqual(UIHarnessFixtures.decode(Achievement.self, table: "achievements").count, 9)
        let progress = UIHarnessFixtures.decode(UserAchievement.self, table: "user_achievements")
        XCTAssertEqual(progress.filter { $0.unlockedAt != nil }.count, 4)

        let categories = UIHarnessFixtures.decode(AkifiIOS.Category.self, table: "categories")
        XCTAssertEqual(categories.count, 7)
        XCTAssertEqual(categories.filter { !$0.isActive }.count, 1)
    }

    func test_fixtures_journalNotesCoverEveryCardVariant() {
        let notes = UIHarnessFixtures.notes()
        XCTAssertTrue(notes.contains { $0.noteType == .reflection && $0.periodStart != nil })
        XCTAssertTrue(notes.contains { $0.noteType == .freeform && $0.transactionId != nil })
        // More tags than the filter bar shows, so the "+N" chip appears.
        XCTAssertGreaterThan(UIHarnessFixtures.journalTags.count, 5)
    }

    // MARK: - Screen routes

    func test_screens_everyRouteHasAName() {
        for screen in UIHarnessScreen.allCases {
            XCTAssertEqual(UIHarnessScreen(rawValue: screen.rawValue), screen)
        }
        XCTAssertEqual(UIHarnessScreen.settings.presentation, .root)
        XCTAssertEqual(UIHarnessScreen.savings.presentation, .push)
        XCTAssertEqual(UIHarnessScreen.challengeDetail.presentation, .sheet)
        XCTAssertEqual(UIHarnessScreen.levelUp.presentation, .overlay)
    }
}
#endif
