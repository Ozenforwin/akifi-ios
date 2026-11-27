import Foundation
import Supabase

/// «Долги» data access — contract `.claude/design/debts-contract.md` §A3–§A6.
/// Money never moves here: movements are ordinary manual transfers written
/// through `DataStore.addTransaction` (`DebtTransferBuilder`).
final class DebtRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    /// Every debt of the caller with server-computed balances (§A4).
    func fetchSummary() async throws -> DebtsSummary {
        // bounded-fetch: single jsonb — debts_summary returns one value, not a row set.
        try await supabase
            .rpc("debts_summary", params: EmptyParams())
            .execute()
            .value
    }

    /// Every `debts` row of the caller (RLS: owner only). The summary has
    /// the same details; this is for a full resync of the side table.
    func fetchAll() async throws -> [Debt] {
        try await SupabasePaging.all("debts", tiebreak: ["account_id"]) { count in
            supabase
                .from("debts")
                .select(count: count)
                .order("created_at")
        }
    }

    /// `create_debt` (§A3): the debt account + its details in one
    /// transaction, no money. Idempotent on the client-generated
    /// `input.accountId`: a retry fails with 23505, which means "already
    /// created" — returned as success.
    @discardableResult
    func create(_ input: CreateDebtParams) async throws -> String {
        do {
            let id: String = try await supabase
                .rpc("create_debt", params: input)
                .execute()
                .value
            return id.lowercased()
        } catch let error as PostgrestError where error.code == "23505" {
            return input.p_account_id
        }
    }

    /// PATCH `debts` details (§A6). Every field is sent (nulls clear).
    func updateDetails(accountId: String, _ details: DebtDetailsPatch) async throws {
        try await supabase
            .from("debts")
            .update(details)
            .eq("account_id", value: accountId)
            .execute()
    }

    /// Name / icon / colour live on the account. `account_type` is never sent.
    func renameAccount(accountId: String, name: String) async throws {
        struct Body: Encodable { let name: String }
        try await supabase
            .from("accounts")
            .update(Body(name: name))
            .eq("id", value: accountId)
            .execute()
    }

    /// Close (`closed_at = now()`) or reopen (`null`) a debt (§A6).
    func setClosed(accountId: String, closed: Bool, now: Date = Date()) async throws {
        try await supabase
            .from("debts")
            .update(ClosedPatch(closed_at: closed ? AppDateFormatters.nowTimestamp(now) : nil))
            .eq("account_id", value: accountId)
            .execute()
    }

    /// Deletes the debt account — cascades the `debts` row and the
    /// debt-account legs; the legs on real accounts stay (§A6).
    func delete(accountId: String) async throws {
        try await supabase
            .from("accounts")
            .delete()
            .eq("id", value: accountId)
            .execute()
    }
}

private struct EmptyParams: Encodable, Sendable {}

private struct ClosedPatch: Encodable, Sendable {
    let closed_at: String?
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(closed_at, forKey: .closed_at)  // null reopens
    }
    enum CodingKeys: String, CodingKey { case closed_at }
}

/// Body of `create_debt` — all 10 keys, nulls explicit (§A3), so PostgREST
/// matches the one overload.
struct CreateDebtParams: Encodable, Sendable, Equatable {
    let p_account_id: String
    let p_name: String?
    let p_currency: String
    let p_icon: String?
    let p_color: String?
    let p_counterparty_name: String
    let p_counterparty_contact: String?
    /// "yyyy-MM-dd".
    let p_due_date: String?
    let p_remind: Bool
    let p_note: String?

    enum CodingKeys: String, CodingKey {
        case p_account_id, p_name, p_currency, p_icon, p_color
        case p_counterparty_name, p_counterparty_contact, p_due_date, p_remind, p_note
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(p_account_id, forKey: .p_account_id)
        try c.encode(p_name, forKey: .p_name)
        try c.encode(p_currency, forKey: .p_currency)
        try c.encode(p_icon, forKey: .p_icon)
        try c.encode(p_color, forKey: .p_color)
        try c.encode(p_counterparty_name, forKey: .p_counterparty_name)
        try c.encode(p_counterparty_contact, forKey: .p_counterparty_contact)
        try c.encode(p_due_date, forKey: .p_due_date)
        try c.encode(p_remind, forKey: .p_remind)
        try c.encode(p_note, forKey: .p_note)
    }

    /// From the form. The account icon is an emoji like every other account
    /// in this app (rows render `Text(account.icon)`); the colour is the
    /// contract's default amber.
    static func make(
        accountId: String = UUID().uuidString.lowercased(),
        name: String,
        currency: String,
        contact: String?,
        dueDate: String?,
        remind: Bool,
        note: String?
    ) -> CreateDebtParams {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return CreateDebtParams(
            p_account_id: accountId,
            p_name: trimmedName,
            p_currency: currency.lowercased(),
            p_icon: DebtDefaults.icon,
            p_color: DebtDefaults.color,
            p_counterparty_name: trimmedName,
            p_counterparty_contact: contact.nonBlank,
            p_due_date: dueDate,
            p_remind: remind && dueDate != nil,
            p_note: note.nonBlank
        )
    }
}

/// PATCH body for `debts` details (§A6) — all five keys, nulls explicit.
struct DebtDetailsPatch: Encodable, Sendable, Equatable {
    let counterparty_name: String
    let counterparty_contact: String?
    let due_date: String?
    let remind: Bool
    let note: String?

    enum CodingKeys: String, CodingKey { case counterparty_name, counterparty_contact, due_date, remind, note }

    init(name: String, contact: String?, dueDate: String?, remind: Bool, note: String?) {
        counterparty_name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        counterparty_contact = contact.nonBlank
        due_date = dueDate
        self.remind = remind && dueDate != nil
        self.note = note.nonBlank
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(counterparty_name, forKey: .counterparty_name)
        try c.encode(counterparty_contact, forKey: .counterparty_contact)
        try c.encode(due_date, forKey: .due_date)
        try c.encode(remind, forKey: .remind)
        try c.encode(note, forKey: .note)
    }
}

enum DebtDefaults {
    static let icon = "👤"
    static let color = "#F59E0B"
}

private extension Optional where Wrapped == String {
    /// Trimmed, nil when blank.
    var nonBlank: String? {
        guard let s = self?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
