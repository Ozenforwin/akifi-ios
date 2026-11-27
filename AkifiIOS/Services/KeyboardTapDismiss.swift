import UIKit

/// Policy of the window-wide «tap outside to hide the keyboard» gesture
/// installed by `AkifiApp`.
///
/// The gesture used to fire on every tap, controls included, and delayed
/// their touch-up: with the keyboard up, the first tap on a segmented
/// control (quick entry's Расход / Доход) only hid the keyboard — the sheet
/// slid down under the finger and the segment never switched; a second tap
/// was needed. Now:
/// - a tap on a UIKit control (segmented control, switch, text field…) never
///   hides the keyboard, and touch-ups are not delayed;
/// - quick entry keeps the keyboard up while chips, the type and the
///   account are picked, so it suspends the gesture while it is on screen.
@MainActor
final class KeyboardTapDismiss: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardTapDismiss()

    private(set) var suspensions = 0

    var isSuspended: Bool { suspensions > 0 }

    /// Balanced with `resume()` (a counter, so nested screens can't
    /// re-enable it for each other).
    func suspend() { suspensions += 1 }

    func resume() { suspensions = max(0, suspensions - 1) }

    /// Whether a tap on `touchedView` should hide the keyboard.
    func shouldDismiss(touchedView: UIView?) -> Bool {
        if isSuspended { return false }
        var view = touchedView
        while let current = view {
            if current is UIControl { return false }
            view = current.superview
        }
        return true
    }

    /// Configures the window's recognizer: never swallows or delays the
    /// touch, asks this policy first.
    func configure(_ tap: UITapGestureRecognizer) {
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        shouldDismiss(touchedView: touch.view)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
