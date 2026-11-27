import Foundation

/// Email-link plumbing for sign-up confirmation and password reset (A1).
///
/// signUp / resend / resetPasswordForEmail pass `callbackURL` as the
/// redirect, so the link in the email opens the app instead of the old
/// web site. The Supabase client uses the PKCE flow: the link carries a
/// one-time `code` that only the device which started the flow can
/// exchange (it holds the code verifier).
///
/// Supabase Auth must list `akifi://auth-callback` in Redirect URLs, or
/// the server falls back to the Site URL.
enum AuthRedirect {
    static let callbackURL = URL(string: "akifi://auth-callback")!

    /// Which email flow a callback belongs to.
    enum Flow: String {
        case signup
        case recovery
    }

    /// Why an email link could not sign the user in.
    enum LinkError: Equatable {
        /// The server rejected the link: expired, already used, or
        /// superseded by a newer email (`otp_expired`, `access_denied`).
        case expiredOrUsed
        /// The link is valid but this device didn't start the flow (other
        /// device, reinstall) — no PKCE code verifier here.
        case otherDevice
        case other(String)
    }

    // MARK: - URL parsing

    static func isCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "akifi" && url.host?.lowercased() == "auth-callback"
    }

    /// Query and fragment parameters merged (GoTrue puts errors in either).
    static func parameters(of url: URL) -> [String: String] {
        var result: [String: String] = [:]
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        for item in components?.queryItems ?? [] {
            result[item.name] = item.value ?? ""
        }
        if let fragment = components?.fragment {
            var fragmentComponents = URLComponents()
            fragmentComponents.query = fragment
            for item in fragmentComponents.queryItems ?? [] {
                result[item.name] = item.value ?? ""
            }
        }
        return result
    }

    /// The error the server put into the redirect, if any.
    static func linkError(in url: URL) -> LinkError? {
        let params = parameters(of: url)
        guard params["error"] != nil || params["error_code"] != nil || params["error_description"] != nil else {
            return nil
        }
        let code = (params["error_code"] ?? params["error"] ?? "").lowercased()
        if ["otp_expired", "access_denied", "flow_state_expired", "flow_state_not_found", "bad_code_verifier"].contains(code) {
            return .expiredOrUsed
        }
        return .other(params["error_description"] ?? code)
    }

    // MARK: - Flow detection

    /// Recovery or sign-up. The server is authoritative: a session issued
    /// for a password-reset link carries `{"method": "recovery"}` in the
    /// access token's `amr` claim. Without that claim, fall back to the
    /// flow this device started last — the one whose code verifier the
    /// exchange just consumed.
    static func flow(accessToken: String, pendingFlow: Flow?) -> Flow {
        if let methods = authenticationMethods(in: accessToken) {
            if methods.contains("recovery") { return .recovery }
            if !methods.isEmpty { return .signup }
        }
        return pendingFlow ?? .signup
    }

    /// `amr[].method` of a JWT, or nil when the token can't be decoded.
    static func authenticationMethods(in jwt: String) -> [String]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let amr = payload["amr"] as? [Any] else { return [] }
        return amr.compactMap { ($0 as? [String: Any])?["method"] as? String }
    }

    // MARK: - Pending flow marker

    static let pendingFlowKey = "auth.pendingEmailFlow"

    static func setPendingFlow(_ flow: Flow?, defaults: UserDefaults = .standard) {
        if let flow {
            defaults.set(flow.rawValue, forKey: pendingFlowKey)
        } else {
            defaults.removeObject(forKey: pendingFlowKey)
        }
    }

    static func pendingFlow(defaults: UserDefaults = .standard) -> Flow? {
        defaults.string(forKey: pendingFlowKey).flatMap(Flow.init(rawValue:))
    }

    // MARK: - Messages

    static func message(for error: LinkError) -> String {
        switch error {
        case .expiredOrUsed: String(localized: "auth.emailLink.expired")
        case .otherDevice: String(localized: "auth.emailLink.otherDevice")
        case .other: String(localized: "auth.emailLink.failed")
        }
    }
}
