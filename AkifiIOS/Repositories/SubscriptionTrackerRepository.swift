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

    /// Patch just the last/next payment dates — used after `recordPayment`.
    func updateDates(id: String, lastPaymentDate: String?, nextPaymentDate: String?) async throws {
        let patch = UpdateSubscriptionDatesInput(
            last_payment_date: lastPaymentDate,
            next_payment_date: nextPaymentDate
        )
        try await supabase
            .from("subscriptions")
            .update(patch)
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

    // MARK: - Payments

    func fetchPayments(for subscriptionId: String) async throws -> [SubscriptionPayment] {
        try await supabase
            .from("subscription_payments")
            .select()
            .eq("subscription_id", value: subscriptionId)
            .order("payment_date", ascending: false)
            .execute()
            .value
    }

    func addPayment(_ input: CreateSubscriptionPaymentInput) async throws -> SubscriptionPayment {
        try await supabase
            .from("subscription_payments")
            .insert(input)
            .select()
            .single()
            .execute()
            .value
    }

    func deletePayment(id: String) async throws {
        try await supabase
            .from("subscription_payments")
            .delete()
            .eq("id", value: id)
            .execute()
    }
}

// MARK: - DTOs

struct CreateSubscriptionInput: Encodable, Sendable {
    let user_id: String
    let service_name: String
    let amount: Decimal
    let billing_period: String
    let start_date: String
    let last_payment_date: String?
    let next_payment_date: String?
    let icon_color: String?
    let reminder_days: Int?
    let currency: String?
}

struct UpdateSubscriptionInput: Encodable, Sendable {
    let service_name: String?
    let amount: Decimal?
    let billing_period: String?
    let start_date: String?
    let last_payment_date: String?
    let next_payment_date: String?
    let icon_color: String?
    let reminder_days: Int?
    let currency: String?
}

struct UpdateSubscriptionDatesInput: Encodable, Sendable {
    let last_payment_date: String?
    let next_payment_date: String?
}

struct CreateSubscriptionPaymentInput: Encodable, Sendable {
    let subscription_id: String
    let amount: Decimal
    let currency: String
    let payment_date: String
}
