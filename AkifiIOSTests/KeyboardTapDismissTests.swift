import XCTest
import UIKit
@testable import AkifiIOS

/// The window-wide tap-to-hide-keyboard gesture must not eat taps meant for
/// controls (device feedback 2026-11-28: the first tap on quick entry's
/// Расход / Доход only hid the keyboard).
@MainActor
final class KeyboardTapDismissTests: XCTestCase {

    func testPlainViewTapHidesTheKeyboard() {
        let policy = KeyboardTapDismiss()
        XCTAssertTrue(policy.shouldDismiss(touchedView: UIView()))
        XCTAssertTrue(policy.shouldDismiss(touchedView: nil))
    }

    func testTapOnAControlOrInsideOneDoesNot() {
        let policy = KeyboardTapDismiss()
        let segmented = UISegmentedControl(items: ["Расход", "Доход", "Перевод"])
        let inner = UIView()
        segmented.addSubview(inner)
        XCTAssertFalse(policy.shouldDismiss(touchedView: segmented))
        XCTAssertFalse(policy.shouldDismiss(touchedView: inner))
        XCTAssertFalse(policy.shouldDismiss(touchedView: UISwitch()))
        XCTAssertFalse(policy.shouldDismiss(touchedView: UITextField()))
    }

    func testSuspensionIsCountedAndBalanced() {
        let policy = KeyboardTapDismiss()
        policy.suspend()
        policy.suspend()
        XCTAssertFalse(policy.shouldDismiss(touchedView: UIView()))
        policy.resume()
        XCTAssertTrue(policy.isSuspended, "one screen still holds it")
        policy.resume()
        XCTAssertTrue(policy.shouldDismiss(touchedView: UIView()))
        policy.resume()
        XCTAssertEqual(policy.suspensions, 0, "never negative")
    }

    func testConfigureNeverSwallowsOrDelaysTouches() {
        let policy = KeyboardTapDismiss()
        let tap = UITapGestureRecognizer()
        policy.configure(tap)
        XCTAssertFalse(tap.cancelsTouchesInView)
        XCTAssertFalse(tap.delaysTouchesEnded)
        XCTAssertTrue(tap.delegate === policy)
    }
}
