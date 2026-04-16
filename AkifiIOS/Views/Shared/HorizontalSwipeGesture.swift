import SwiftUI
import UIKit

/// A UIKit-backed pan gesture that only starts when the user drags
/// predominantly horizontally. Designed to coexist with an enclosing
/// `ScrollView` so vertical pans are never swallowed.
///
/// Standard iOS pattern for swipe-to-delete rows inside vertical scrollers.
struct HorizontalSwipeGesture: UIViewRepresentable {
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let recognizer = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onEnded: onEnded)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat) -> Void

        init(onChanged: @escaping (CGFloat) -> Void, onEnded: @escaping (CGFloat) -> Void) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            let translation = g.translation(in: g.view)
            switch g.state {
            case .changed:
                onChanged(translation.x)
            case .ended, .cancelled, .failed:
                onEnded(translation.x)
            default:
                break
            }
        }

        /// Only begin recognition when the user's initial direction is
        /// clearly horizontal. This check runs once at gesture start — after
        /// that, the system manages the lifecycle normally.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y)
        }

        /// Allow the enclosing ScrollView's pan recogniser to run alongside
        /// ours, so vertical scrolling works even when the user's finger is
        /// on a card. We'll still decline to start in `shouldBegin` when the
        /// motion is vertical.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
