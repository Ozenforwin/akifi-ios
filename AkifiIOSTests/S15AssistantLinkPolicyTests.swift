import XCTest
@testable import AkifiIOS

/// S15: a link a partner planted in a transaction description and the
/// model echoed must not render as a tap target.
final class S15AssistantLinkPolicyTests: XCTestCase {

    private func links(in text: String) -> [URL] {
        AssistantLinkPolicy.inlineMarkdown(text).runs.compactMap(\.link)
    }

    func test_S15_foreignLink_losesTapTarget_keepsWords() {
        let rendered = AssistantLinkPolicy.inlineMarkdown("Срочно: [Подтвердите вход](https://akifi-login.example/x) сегодня")
        XCTAssertTrue(rendered.runs.allSatisfy { $0.link == nil })
        XCTAssertEqual(String(rendered.characters), "Срочно: Подтвердите вход сегодня")
    }

    func test_S15_lookalikeHosts_blocked() {
        for url in [
            "https://akifi.pro.evil.example/",
            "https://evilakifi.pro/",
            "http://akifi.pro/",          // not https
            "javascript:alert(1)",
            "tel:+70000000000",
            "mailto:a@b.c",
            "/relative/path",
        ] {
            XCTAssertTrue(links(in: "[x](\(url))").isEmpty, url)
        }
    }

    func test_S15_autolink_blocked() {
        XCTAssertTrue(links(in: "<https://evil.example/login>").isEmpty)
    }

    func test_S15_ownDestinations_stayTappable() {
        XCTAssertEqual(links(in: "[Сайт](https://akifi.pro/help)").map(\.absoluteString), ["https://akifi.pro/help"])
        XCTAssertEqual(links(in: "[Блог](https://blog.akifi.pro/post)").count, 1)
        XCTAssertEqual(links(in: "[Бюджеты](akifi://budgets)").map(\.absoluteString), ["akifi://budgets"])
    }

    func test_S15_inviteLinks_blockedEvenOnOwnDomain() {
        XCTAssertTrue(links(in: "[Вступить](akifi://budget-invite/0123456789abcdef0123)").isEmpty)
        XCTAssertTrue(links(in: "[Вступить](akifi://invite/0123456789abcdef0123)").isEmpty)
        XCTAssertTrue(links(in: "[Вступить](https://akifi.pro/invite/0123456789abcdef0123)").isEmpty)
    }

    func test_S15_formattingSurvivesSanitizing() {
        let rendered = AssistantLinkPolicy.inlineMarkdown("**Итого** за [месяц](https://evil.example): 5 000 ₽")
        XCTAssertEqual(String(rendered.characters), "Итого за месяц: 5 000 ₽")
        let bold = rendered.runs.first { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        XCTAssertNotNil(bold)
    }
}
