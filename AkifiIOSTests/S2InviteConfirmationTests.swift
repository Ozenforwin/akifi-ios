import XCTest
@testable import AkifiIOS

/// S2: an invite link opens a confirmation (who, where, role, what is
/// shared) and never joins by itself.
final class S2InviteConfirmationTests: XCTestCase {

    private let code = "0123456789abcdef0123456789abcdef"

    // MARK: - Link parsing (every form the old handler accepted)

    func test_S2_parsesEveryInviteLinkForm() {
        XCTAssertEqual(DeepLink.parse(URL(string: "akifi://invite/\(code)")!), .accountInvite(code: code))
        XCTAssertEqual(DeepLink.parse(URL(string: "akifi://budget-invite/\(code)")!), .budgetInvite(code: code))
        XCTAssertEqual(DeepLink.parse(URL(string: "https://akifi.pro/invite/\(code)")!), .accountInvite(code: code))
        XCTAssertEqual(DeepLink.parse(URL(string: "https://akifi.pro/budget-invite/\(code)")!), .budgetInvite(code: code))
    }

    func test_S2_rejectsShortOrMissingCodes() {
        XCTAssertNil(DeepLink.parse(URL(string: "akifi://invite/short")!))
        XCTAssertNil(DeepLink.parse(URL(string: "akifi://invite/")!))
        XCTAssertNil(DeepLink.parse(URL(string: "https://akifi.pro/invite")!))
        XCTAssertNil(DeepLink.parse(URL(string: "https://evil.example/invite/\(code)")!))
    }

    func test_S2_widgetAndAuthLinksStillRoute() {
        XCTAssertEqual(DeepLink.parse(URL(string: "akifi://home")!), .tab(.home))
        XCTAssertEqual(DeepLink.parse(URL(string: "akifi://budgets")!), .tab(.budgets))
        XCTAssertEqual(DeepLink.parse(URL(string: "akifi://transactions")!), .tab(.transactions))
        XCTAssertEqual(DeepLink.parse(URL(string: "akifi://analytics")!), .tab(.analytics))
        let callback = URL(string: "akifi://auth-callback?code=x")!
        XCTAssertEqual(DeepLink.parse(callback), .authCallback(callback))
        XCTAssertNil(DeepLink.parse(URL(string: "com.googleusercontent.apps.1:/oauth?code=x")!))
    }

    @MainActor
    func test_S2_inviteLinkWaitsForTheSignedInUI() {
        let vm = AppViewModel()
        vm.open(URL(string: "akifi://budget-invite/\(code)")!)
        XCTAssertEqual(vm.pendingDeepLink, .budgetInvite(code: code))
        vm.resetForSignOut()
        XCTAssertNil(vm.pendingDeepLink, "a pending invite never carries over to the next account")
    }

    // MARK: - Preview decoding

    func test_S2_previewDecodes() throws {
        let json = #"{"found": true, "kind": "budget", "role": "viewer", "inviter_name": "Иван", "target_name": "Семья", "category_filter": "false"}"#
        let preview = try XCTUnwrap(InvitePreview.decode(Data(json.utf8)))
        XCTAssertEqual(preview.status, .pending)
        XCTAssertEqual(preview.kind, .budget)
        XCTAssertEqual(preview.role, "viewer")
        XCTAssertEqual(preview.inviterName, "Иван")
        XCTAssertEqual(preview.targetName, "Семья")
        XCTAssertEqual(preview.budgetHasCategoryFilter, false)
    }

    func test_S2_previewStatuses() {
        XCTAssertEqual(InvitePreview.decode(Data(#"{"found": false, "error": "invite_expired"}"#.utf8))?.status, .expired)
        XCTAssertEqual(InvitePreview.decode(Data(#"{"found": "false", "error": "invite_not_found"}"#.utf8))?.status, .notFound)
        XCTAssertNil(InvitePreview.decode(Data("[]".utf8)))
        XCTAssertNil(InvitePreview.decode(Data(#"{"kind": "budget"}"#.utf8)))
    }

    // MARK: - Disclosure

    func test_S2_budgetWithoutCategories_saysAllExpensesAreShared() {
        let preview = InvitePreview(status: .pending, kind: .budget, role: "viewer", inviterName: "Иван",
                                    targetName: "Семья", budgetHasCategoryFilter: false)
        let d = InviteDisclosure.make(linkKind: .account, preview: preview)
        XCTAssertEqual(d.title, String(localized: "invite.confirm.title.budget"), "the server's kind wins over the link's")
        XCTAssertTrue(d.shares.contains(String(localized: "invite.confirm.budget.allExpenses")))
        XCTAssertNil(d.warning)
        XCTAssertNotNil(d.inviterLine)
        XCTAssertEqual(d.roleLine, String(localized: "invite.confirm.role.viewer"))
    }

    func test_S2_noPreview_warnsAndCoversTheOtherKind() {
        let account = InviteDisclosure.make(linkKind: .account, preview: nil)
        XCTAssertEqual(account.warning, String(localized: "invite.confirm.unknownInviter"))
        XCTAssertNil(account.inviterLine)
        XCTAssertNil(account.roleLine)
        XCTAssertTrue(account.shares.contains(String(localized: "invite.confirm.maybeBudget")),
                      "an /invite/ link may resolve to a budget — the 400-day disclosure must be there")
        XCTAssertTrue(account.shares.contains(String(localized: "invite.confirm.profile")))

        let budget = InviteDisclosure.make(linkKind: .budget, preview: nil)
        XCTAssertTrue(budget.shares.contains(String(localized: "invite.confirm.budget.yourExpenses")))
        XCTAssertTrue(budget.shares.contains(String(localized: "invite.confirm.maybeAccount")))
    }

    func test_S2_expiredPreview_isNotTreatedAsKnown() {
        let expired = InvitePreview(status: .expired, kind: nil, role: nil, inviterName: nil,
                                    targetName: nil, budgetHasCategoryFilter: nil)
        let d = InviteDisclosure.make(linkKind: .account, preview: expired)
        XCTAssertNotNil(d.warning)
    }
}
