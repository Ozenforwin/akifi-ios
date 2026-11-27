import XCTest
import PostgREST
@testable import AkifiIOS

/// Device feedback 2026-11-28: «Дал в долг» showed the raw PostgREST text
/// «Could not find the function public.create_debt(…) in the schema cache»
/// (the debts migration isn't on the server yet).
final class ServerNotReadyErrorTests: XCTestCase {

    func testMissingFunctionOrTableIsAFriendlyMessage() {
        let expected = String(localized: "server.error.featureNotReady")
        for code in ["PGRST202", "PGRST205", "42883", "42P01"] {
            let error = PostgrestError(
                code: code,
                message: "Could not find the function public.create_debt(p_account_id, p_color) in the schema cache"
            )
            XCTAssertEqual(FormErrorMessage.text(for: error), expected, code)
            XCTAssertFalse(FormErrorMessage.text(for: error).contains("schema cache"))
        }
    }

    func testOtherErrorsAreUnchanged() {
        let error = PostgrestError(code: "P0002", message: "Expense x not found")
        XCTAssertEqual(FormErrorMessage.text(for: error), String(localized: "tx.error.alreadyDeleted"))
    }
}
