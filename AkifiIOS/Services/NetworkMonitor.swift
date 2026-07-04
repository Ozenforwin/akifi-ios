import Foundation
import Network

@Observable @MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()
    private(set) var isConnected = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")

    private init() {
        let monitor = self.monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.isConnected = satisfied
            }
        }
        monitor.start(queue: queue)
    }
}

struct TimeoutError: LocalizedError {
    let seconds: Double
    var errorDescription: String? { "Operation timed out after \(Int(seconds))s" }
}

/// Runs `operation` with a HARD deadline: the call returns (or throws
/// `TimeoutError`) no later than `seconds`, even when the operation does
/// not honor cooperative cancellation.
///
/// The previous TaskGroup-based implementation had a trap: after the
/// timeout child threw, the group still awaited the cancelled operation
/// child — an SDK call that ignores cancellation (e.g. a token refresh
/// stuck in airplane mode) kept the "timed-out" caller hanging forever.
/// This version races unstructured tasks through a continuation guarded
/// by a latch; a hung operation keeps running detached and is dropped.
func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let stream = AsyncThrowingStream<T, Error> { continuation in
        let work = Task {
            do {
                continuation.yield(try await operation())
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        let timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            // Second finish after a completed operation is a safe no-op.
            continuation.finish(throwing: TimeoutError(seconds: seconds))
            work.cancel()
        }
        continuation.onTermination = { _ in
            work.cancel()
            timer.cancel()
        }
    }

    for try await value in stream {
        return value
    }
    throw TimeoutError(seconds: seconds)
}
