import Foundation

/// Which links in an assistant answer stay tappable (S15).
///
/// The answer is model output, and the model reads text other people
/// wrote — a partner's transaction descriptions in a shared account. A
/// description like "[Подтвердите вход](https://evil.example)" can come
/// back verbatim in the answer and render as a real link. Only the app's
/// own destinations keep their link; everything else renders as plain
/// text (the words stay, the tap target goes).
enum AssistantLinkPolicy {
    /// Web hosts the app owns (subdomains included).
    static let allowedHosts: Set<String> = ["akifi.pro"]

    /// `akifi://` destinations that only navigate inside the app. Invite
    /// links are deliberately absent: a planted invite must not be one tap
    /// away from the answer.
    static let allowedAppHosts: Set<String> = ["home", "budgets", "transactions", "analytics"]

    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "akifi":
            guard let host = url.host?.lowercased() else { return false }
            return allowedAppHosts.contains(host)
        case "https":
            guard let host = url.host?.lowercased(),
                  allowedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
            else { return false }
            // Universal links into the invite flow — same reason as above.
            return !url.pathComponents.contains { $0.lowercased().contains("invite") }
        default:
            return false
        }
    }

    /// Copy of `text` with every disallowed `.link` removed.
    static func sanitize(_ text: AttributedString) -> AttributedString {
        var result = AttributedString()
        for run in text.runs {
            var piece = AttributedString(text[run.range])
            if let link = run.link, !isAllowed(link) {
                piece.link = nil
            }
            result.append(piece)
        }
        return result
    }

    /// Inline markdown of an assistant answer, links filtered.
    static func inlineMarkdown(_ text: String) -> AttributedString {
        guard let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return AttributedString(text)
        }
        return sanitize(parsed)
    }
}
