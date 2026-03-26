import Foundation

@Observable @MainActor
final class SubscriptionsViewModel {
    var subscriptions: [SubscriptionTracker] = []
    var isLoading = false
    var error: String?
    var showForm = false

    private let repo = SubscriptionTrackerRepository()

    var monthlyTotal: Int64 {
        subscriptions.reduce(Int64(0)) { total, sub in
            switch sub.billingPeriod {
            case .monthly: total + sub.amount
            case .quarterly: total + sub.amount / 3
            case .yearly: total + sub.amount / 12
            }
        }
    }

    func load() async {
        isLoading = true
        error = nil
        do {
            subscriptions = try await repo.fetchAll()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func create(name: String, amount: Int64, period: BillingPeriod, color: String?) async {
        do {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            let input = CreateSubscriptionInput(
                service_name: name,
                amount: amount,
                billing_period: period.rawValue,
                start_date: df.string(from: Date()),
                icon_color: color
            )
            let sub = try await repo.create(input)
            subscriptions.append(sub)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func delete(_ sub: SubscriptionTracker) async {
        do {
            try await repo.delete(id: sub.id)
            subscriptions.removeAll { $0.id == sub.id }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
