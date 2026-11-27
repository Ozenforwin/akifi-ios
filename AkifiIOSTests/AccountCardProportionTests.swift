import SwiftUI
import XCTest
@testable import AkifiIOS

/// Device feedback 2026-11-28: «сделай по высоте счета чуть повыше чтобы
/// туда встали карточки из apple pay» — the account card (and the cover
/// crop) take a bank card's proportions.
@MainActor
final class AccountCardProportionTests: XCTestCase {

    func testTheCardHasABankCardsProportions() {
        // ISO/IEC 7810 ID-1: 85.60 × 53.98 mm — the shape of a Wallet card.
        XCTAssertEqual(AccountCoverCrop.cardAspect, 1.5858, accuracy: 0.0005)
    }

    func testProportionalHeight() {
        XCTAssertEqual(BankCardProportionLayout.proportionalHeight(width: 370, aspect: AccountCoverCrop.cardAspect, cap: 420),
                       370 / AccountCoverCrop.cardAspect, accuracy: 0.001)
        XCTAssertEqual(BankCardProportionLayout.proportionalHeight(width: 1000, aspect: AccountCoverCrop.cardAspect, cap: 420), 420)
        XCTAssertEqual(BankCardProportionLayout.proportionalHeight(width: 0, aspect: 1.5, cap: 420), 0)
        XCTAssertEqual(BankCardProportionLayout.proportionalHeight(width: .infinity, aspect: 1.5, cap: 420), 0)
    }

    /// The layout gives short content the bank-card height and lets tall
    /// content (Dynamic Type) grow past it.
    func testTheLayoutKeepsTheProportionAndGrowsForContent() throws {
        let width: CGFloat = 370
        func renderedHeight<Content: View>(_ content: Content) throws -> CGFloat {
            let renderer = ImageRenderer(content: BankCardProportionLayout(aspect: AccountCoverCrop.cardAspect) {
                content
            }
            .frame(width: width))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            return CGFloat(image.height)
        }
        let short = try renderedHeight(VStack { Text(verbatim: "Семейный"); Spacer(minLength: 0); Text(verbatim: "837,96 $") })
        XCTAssertEqual(short, (width / AccountCoverCrop.cardAspect).rounded(), accuracy: 1)

        let tall = try renderedHeight(Color.red.frame(height: 400))
        XCTAssertEqual(tall, 400, accuracy: 1)
    }
}
