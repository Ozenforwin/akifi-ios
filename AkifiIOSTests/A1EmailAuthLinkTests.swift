import XCTest
import Supabase
@testable import AkifiIOS

/// A1: sign-up confirmation and password-reset links come back into the
/// app and finish there.
final class A1EmailAuthLinkTests: XCTestCase {

    // MARK: - Helpers

    /// Unsigned JWT with the given payload (only the payload is read).
    private func jwt(_ payload: [String: Any]) -> String {
        func b64url(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64url(try! JSONSerialization.data(withJSONObject: ["alg": "HS256", "typ": "JWT"]))
        let body = b64url(try! JSONSerialization.data(withJSONObject: payload))
        return "\(header).\(body).signature"
    }

    private func apiError(_ code: ErrorCode, message: String) -> AuthError {
        AuthError.api(
            message: message,
            errorCode: code,
            underlyingData: Data(),
            underlyingResponse: HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: 400,
                                                httpVersion: nil, headerFields: nil)!
        )
    }

    // MARK: - Redirect

    func test_A1_redirectIsTheAppScheme() {
        XCTAssertEqual(AuthRedirect.callbackURL.absoluteString, "akifi://auth-callback")
        XCTAssertTrue(AuthRedirect.isCallback(URL(string: "akifi://auth-callback?code=abc")!))
        XCTAssertTrue(AuthRedirect.isCallback(URL(string: "AKIFI://Auth-Callback#error=x")!))
        XCTAssertFalse(AuthRedirect.isCallback(URL(string: "akifi://invite/0123456789abcdef")!))
        XCTAssertFalse(AuthRedirect.isCallback(URL(string: "https://akifi.pro/auth-callback")!))
    }

    func test_A1_serverErrorsInQueryOrFragment() {
        let expired = URL(string: "akifi://auth-callback#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired")!
        XCTAssertEqual(AuthRedirect.linkError(in: expired), .expiredOrUsed)
        let query = URL(string: "akifi://auth-callback?error=server_error&error_description=boom")!
        XCTAssertEqual(AuthRedirect.linkError(in: query), .other("boom"))
        XCTAssertNil(AuthRedirect.linkError(in: URL(string: "akifi://auth-callback?code=1234")!))
    }

    // MARK: - Flow detection

    func test_A1_recoveryDetectedFromTheTokenItself() {
        let token = jwt(["sub": "u", "amr": [["method": "recovery", "timestamp": 1_764_000_000]]])
        XCTAssertEqual(AuthRedirect.flow(accessToken: token, pendingFlow: .signup), .recovery,
                       "the server's amr claim wins over the local marker")
    }

    func test_A1_signupDetectedFromTheToken() {
        let token = jwt(["sub": "u", "amr": [["method": "email/signup", "timestamp": 1_764_000_000]]])
        XCTAssertEqual(AuthRedirect.flow(accessToken: token, pendingFlow: .recovery), .signup)
    }

    func test_A1_noClaim_fallsBackToTheFlowThisDeviceStarted() {
        let token = jwt(["sub": "u"])
        XCTAssertEqual(AuthRedirect.flow(accessToken: token, pendingFlow: .recovery), .recovery)
        XCTAssertEqual(AuthRedirect.flow(accessToken: token, pendingFlow: nil), .signup)
        XCTAssertEqual(AuthRedirect.flow(accessToken: "garbage", pendingFlow: .recovery), .recovery)
    }

    func test_A1_pendingFlowMarker_roundTrips() {
        let suite = "A1EmailAuthLinkTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(AuthRedirect.pendingFlow(defaults: defaults))
        AuthRedirect.setPendingFlow(.recovery, defaults: defaults)
        XCTAssertEqual(AuthRedirect.pendingFlow(defaults: defaults), .recovery)
        AuthRedirect.setPendingFlow(nil, defaults: defaults)
        XCTAssertNil(AuthRedirect.pendingFlow(defaults: defaults))
    }

    // MARK: - Errors

    /// The SDK's localizedDescription is "Email not confirmed", not the
    /// code — the old substring match never fired and users got the
    /// generic error with no way to resend.
    func test_A1_emailNotConfirmed_recognizedByCode() {
        let error = apiError(.emailNotConfirmed, message: "Email not confirmed")
        XCTAssertTrue(AuthErrorMapper.isEmailNotConfirmed(error))
        XCTAssertEqual(AuthErrorMapper.message(for: error), String(localized: "auth.error.emailNotConfirmed"))
        XCTAssertFalse(AuthErrorMapper.isEmailNotConfirmed(apiError(.invalidCredentials, message: "Invalid login credentials")))
    }

    func test_A1_serverCodes_mapToSpecificMessages() {
        XCTAssertEqual(AuthErrorMapper.message(for: apiError(.overEmailSendRateLimit, message: "x")),
                       String(localized: "auth.error.rateLimited"))
        XCTAssertEqual(AuthErrorMapper.message(for: apiError(.samePassword, message: "x")),
                       String(localized: "auth.error.samePassword"))
        XCTAssertEqual(AuthErrorMapper.message(for: apiError(.userAlreadyExists, message: "x")),
                       String(localized: "auth.error.alreadyRegistered"))
    }

    // MARK: - New password

    func test_A1_newPassword_sameRulesAsSignUp() {
        XCTAssertTrue(NewPasswordView.isAcceptable("Secret123", confirmation: "Secret123"))
        XCTAssertFalse(NewPasswordView.isAcceptable("Secret123", confirmation: "Secret124"))
        XCTAssertFalse(NewPasswordView.isAcceptable("short1A", confirmation: "short1A"))
        XCTAssertFalse(NewPasswordView.isAcceptable("alllowercase1", confirmation: "alllowercase1"))
        XCTAssertFalse(NewPasswordView.isAcceptable("NoDigitsHere", confirmation: "NoDigitsHere"))
    }

    // MARK: - Routing

    @MainActor
    func test_A1_authCallback_isNotQueuedForTheSignedInUI() {
        let vm = AppViewModel()
        vm.open(URL(string: "akifi://auth-callback#error=access_denied&error_code=otp_expired")!)
        XCTAssertNil(vm.pendingDeepLink, "email links are handled at once, also on the login screen")
    }
}
