import Foundation

/// Every URL the app opens, parsed in one place.
///
/// `ContentView` hands each incoming URL to `AppViewModel.open(_:)`:
/// email-link callbacks are handled immediately (also on the login
/// screen); navigation and invites wait in `pendingDeepLink` until the
/// signed-in UI consumes them — an invite tapped while signed out is no
/// longer lost.
enum DeepLink: Equatable {
    /// Widget targets: akifi://home | budgets | transactions | analytics
    case tab(AppTab)
    /// akifi://invite/<code> · https://akifi.pro/invite/<code>
    case accountInvite(code: String)
    /// akifi://budget-invite/<code> · https://akifi.pro/budget-invite/<code>
    case budgetInvite(code: String)
    /// akifi://auth-callback?code=… — confirmation / password-reset email
    /// links (A1).
    case authCallback(URL)

    /// Shortest code the accept RPCs take (the displayed 16-hex prefix).
    static let minimumInviteCodeLength = 16

    static func parse(_ url: URL) -> DeepLink? {
        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased()

        if scheme == "akifi" {
            switch host {
            case "home": return .tab(.home)
            case "budgets": return .tab(.budgets)
            case "transactions": return .tab(.transactions)
            case "analytics": return .tab(.analytics)
            case "auth-callback": return .authCallback(url)
            case "budget-invite": return inviteCode(url).map { .budgetInvite(code: $0) }
            case "invite": return inviteCode(url).map { .accountInvite(code: $0) }
            default: return nil
            }
        }

        if host == "akifi.pro" {
            // Budget first: "/budget-invite/x" must not read as an account invite.
            if url.pathComponents.contains("budget-invite") {
                return inviteCode(url).map { .budgetInvite(code: $0) }
            }
            if url.pathComponents.contains("invite") {
                return inviteCode(url).map { .accountInvite(code: $0) }
            }
        }
        return nil
    }

    private static func inviteCode(_ url: URL) -> String? {
        guard let last = url.pathComponents.last,
              last != "/",
              last != "invite", last != "budget-invite",
              last.count >= minimumInviteCodeLength
        else { return nil }
        return last
    }
}
