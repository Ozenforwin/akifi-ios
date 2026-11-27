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
        try await SupabasePaging.all("subscriptions") { count in
            supabase
                .from("subscriptions")
                .select(count: count)
                .in("status", values: [SubscriptionTrackerStatus.active.rawValue, SubscriptionTrackerStatus.paused.rawValue])
                .order("next_payment_date")
        }
    }

    /// Fetch *all* subscriptions including cancelled ones — used for the archive view.
    func fetchAllIncludingCancelled() async throws -> [SubscriptionTracker] {
        try await SupabasePaging.all("subscriptions") { count in
            supabase
                .from("subscriptions")
                .select(count: count)
                .order("next_payment_date")
        }
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
        try await SupabasePaging.all("subscription_payments") { count in
            supabase
                .from("subscription_payments")
                .select(count: count)
                .eq("subscription_id", value: subscriptionId)
                .order("payment_date", ascending: false)
        }
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
    let category_id: String?
    let account_id: String?
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
    let category_id: String?
    let account_id: String?
}

/// Both dates as the caller wants them stored — nil is written as NULL.
/// Every caller passes the full intended state (record / undo / delete a
/// payment); a synthesized Encodable dropped nil keys, so restoring "no
/// last payment" after an undo or a history delete left the old date on
/// the row (V8). A NULL `next_payment_date` is recomputed by the
/// subscriptions trigger.
struct UpdateSubscriptionDatesInput: Encodable, Sendable {
    let last_payment_date: String?
    let next_payment_date: String?

    enum CodingKeys: String, CodingKey { case last_payment_date, next_payment_date }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(last_payment_date, forKey: .last_payment_date)
        try c.encode(next_payment_date, forKey: .next_payment_date)
    }
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
