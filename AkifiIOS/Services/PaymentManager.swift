import Foundation

struct PremiumProduct: Sendable {
    let id: String
    let name: String
    let price: Decimal
}

enum PurchaseResult: Sendable {
    case success
    case pending
    case cancelled
}

protocol PaymentServiceProtocol: Sendable {
    func fetchProducts() async throws -> [PremiumProduct]
    func purchase(_ product: PremiumProduct) async throws -> PurchaseResult
    func restorePurchases() async throws -> [PurchaseResult]
}

// Stub implementation for v1 - checks premium via Supabase
@Observable @MainActor
final class PaymentManager {
    var isPremium = false

    private let supabase = SupabaseManager.shared.client

    func checkPremiumStatus() async {
        do {
            let subscription: UserSubscription = try await supabase
                .from("user_subscriptions")
                .select()
                .single()
                .execute()
                .value

            isPremium = subscription.status == .active || subscription.status == .trialing
        } catch {
            isPremium = false
        }
    }
}
