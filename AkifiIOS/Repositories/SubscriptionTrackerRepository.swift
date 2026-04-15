import Foundation
import Supabase

final class SubscriptionTrackerRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    /// Fetch non-cancelled subscriptions (active + paused). Cancelled rows are archived.
    ///
    /// Filters on `status` directly. The DB trigger keeps `is_active` in sync with
    /// `status == 'active'`, so legacy v1.2.2 clients (which filter on `is_active=true`)
    /// still see only active subscriptions.
    func fetchAll() async throws -> [SubscriptionTracker] {
        try await supabase
            .from("subscriptions")
            .select()
            .in("status", values: [SubscriptionTrackerStatus.active.rawValue, SubscriptionTrackerStatus.paused.rawValue])
            .order("next_payment_date")
            .execute()
            .value
    }

    /// Fetch *all* subscriptions including cancelled ones — used for the archive view.
    func fetchAllIncludingCancelled() async throws -> [SubscriptionTracker] {
        try await supabase
            .from("subscriptions")
            .select()
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

    /// Patch just the lifecycle status. The DB trigger mirrors into `is_active`.
    func updateStatus(id: String, _ status: SubscriptionTrackerStatus) async throws {
        let patch = UpdateSubscriptionTrackerStatusInput(status: status.rawValue)
        try await supabase
            .from("subscriptions")
            .update(patch)
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
        // Soft-delete: mark as cancelled. DB trigger mirrors into is_active=false.
        try await updateStatus(id: id, .cancelled)
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
    let status: String?
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
    let status: String?
}

struct UpdateSubscriptionDatesInput: Encodable, Sendable {
    let last_payment_date: String?
    let next_payment_date: String?
}

struct UpdateSubscriptionTrackerStatusInput: Encodable, Sendable {
    let status: String
}

struct CreateSubscriptionPaymentInput: Encodable, Sendable {
    let subscription_id: String
    let amount: Decimal
    let currency: String
    let payment_date: String
}
