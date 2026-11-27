import Foundation

/// A `NotificationCenter` observation that ends when this object is
/// released. The handler runs on the main actor, asynchronously: the
/// notification is delivered on the posting thread (a defaults write may
/// come from any thread) and hops over, so a poster never waits for the
/// main thread.
final class NotificationObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(
        name: Notification.Name,
        center: NotificationCenter = .default,
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) {
        self.center = center
        token = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            Task { @MainActor in handler() }
        }
    }

    deinit {
        center.removeObserver(token)
    }
}
