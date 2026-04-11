import Foundation
import Supabase

final class SubscriptionTrackerRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    func fetchAll() async throws -> [SubscriptionTracker] {
        try await supabase
            .from("subscriptions")
            .select()
            .eq("is_active", value: true)
            .order("next_payment_date")
            .execute()
            .value
    }

    func create(_ input: CreateSubscriptionInput) async throws -> SubscriptionTracker {
        try await supabase
            .from("subscriptions")
            .insert(input)
            .select()
            .single()
            .execute()
            .value
    }

    func update(id: String, _ input: UpdateSubscriptionInput) async throws {
        try await supabase
            .from("subscriptions")
            .update(input)
            .eq("id", value: id)
            .execute()
    }

    func delete(id: String) async throws {
        try await supabase
            .from("subscriptions")
            .update(["is_active": false])
            .eq("id", value: id)
            .execute()
    }
}

struct CreateSubscriptionInput: Encodable, Sendable {
    let user_id: String
    let service_name: String
    let amount: Decimal
    let billing_period: String
    let start_date: String
    let icon_color: String?
    let reminder_days: Int?
    let currency: String?
}

struct UpdateSubscriptionInput: Encodable, Sendable {
    let service_name: String?
    let amount: Decimal?
    let billing_period: String?
    let icon_color: String?
    let reminder_days: Int?
    let currency: String?
}
