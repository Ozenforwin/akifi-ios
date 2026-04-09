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

func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError(seconds: seconds)
        }
        guard let result = try await group.next() else {
            throw TimeoutError(seconds: seconds)
        }
        group.cancelAll()
        return result
    }
}
