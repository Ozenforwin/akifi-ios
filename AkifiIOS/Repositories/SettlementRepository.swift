import Foundation
import Supabase

/// CRUD wrapper around the `settlements` table. All members of a shared
/// account can read and insert; only the creator (`settled_by`) can delete.
final class SettlementRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    /// Fetches all settlements recorded against a shared account, newest first.
    func fetchForAccount(_ accountId: String) async throws -> [Settlement] {
        try await SupabasePaging.all("settlements") { count in
            supabase
                .from("settlements")
                .select(count: count)
                .eq("shared_account_id", value: accountId)
                .order("settled_at", ascending: false)
        }
    }

    /// Inserts a new settlement and returns the server-assigned row. Client
    /// is expected to pre-fill `id` with a UUID (or leave empty — DB has a
    /// default) and `settledBy` with `auth.uid()`.
    func create(_ settlement: CreateSettlementInput) async throws -> Settlement {
        try await supabase
            .from("settlements")
            .insert(settlement)
            .select()
            .single()
            .execute()
            .value
    }

    func delete(id: String) async throws {
        try await supabase
            .from("settlements")
            .delete()
            .eq("id", value: id)
            .execute()
    }

    /// Server-computed "who owes whom" (RPC `get_account_settlement`,
    /// migration 20261117090000). The server sees every row, so the result is
    /// identical for every member — unlike a client computation over the
    /// RLS-filtered transaction list, where each member can't see the other's
    /// personal cards.
    func fetchServerSettlement(_ accountId: String) async throws -> ServerSettlement {
        // bounded-fetch: the RPC returns one jsonb value, not a row set — max-rows cannot apply.
        try await supabase
            .rpc("get_account_settlement", params: ServerSettlementParams(p_account_id: accountId))
            .execute()
            .value
    }
}

private struct ServerSettlementParams: Encodable, Sendable {
    let p_account_id: String
}

/// Response of `get_account_settlement`. All amounts are kopecks in the
/// shared account's currency.
///
/// v2 (migration 20261128090003, contract §B4) adds `personal_share` per
/// balance and `personal_debts`; both decode as optional, so a v1 server
/// reads as "no personal marks".
struct ServerSettlement: Decodable, Sendable, Equatable {
    struct Balance: Decodable, Sendable, Equatable {
        let userId: String
        let contributed: Int64
        let fairShare: Int64
        /// v2: the part of `fairShare` attributed 100 % to this member
        /// (their personal expenses paid via «Оплачено с»). 0 on v1.
        let personalShare: Int64

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case contributed
            case fairShare = "fair_share"
            case personalShare = "personal_share"
        }

        init(userId: String, contributed: Int64, fairShare: Int64, personalShare: Int64 = 0) {
            self.userId = userId; self.contributed = contributed
            self.fairShare = fairShare; self.personalShare = personalShare
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            userId = try c.decode(String.self, forKey: .userId)
            contributed = try c.decode(Int64.self, forKey: .contributed)
            fairShare = try c.decode(Int64.self, forKey: .fairShare)
            personalShare = ((try? c.decodeIfPresent(Int64.self, forKey: .personalShare)) ?? nil) ?? 0
        }
    }

    /// v2: what a member owes THE ACCOUNT for personal spending paid from
    /// its own money (direct expenses marked for them, minus repayments).
    struct PersonalDebt: Decodable, Sendable, Equatable, Identifiable {
        let userId: String
        /// `max(expenses − repaid, 0)` — the number to display.
        let owed: Int64
        let expenses: Int64
        let repaid: Int64
        /// false: a former member who still has non-zero numbers.
        let isMember: Bool

        var id: String { userId }

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case owed, expenses, repaid
            case isMember = "is_member"
        }

        init(userId: String, owed: Int64, expenses: Int64, repaid: Int64, isMember: Bool = true) {
            self.userId = userId; self.owed = owed; self.expenses = expenses
            self.repaid = repaid; self.isMember = isMember
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            userId = try c.decode(String.self, forKey: .userId).lowercased()
            expenses = ((try? c.decodeIfPresent(Int64.self, forKey: .expenses)) ?? nil) ?? 0
            repaid = ((try? c.decodeIfPresent(Int64.self, forKey: .repaid)) ?? nil) ?? 0
            owed = ((try? c.decodeIfPresent(Int64.self, forKey: .owed)) ?? nil) ?? max(expenses - repaid, 0)
            isMember = ((try? c.decodeIfPresent(Bool.self, forKey: .isMember)) ?? nil) ?? true
        }
    }

    let version: Int
    let totalExpenses: Int64
    let balances: [Balance]
    /// Main expense transaction id → payer user id. The single payer
    /// attribution the per-transaction settle UI must use.
    let payers: [String: String]
    /// v2 only; `[]` on a v1 server.
    let personalDebts: [PersonalDebt]

    enum CodingKeys: String, CodingKey {
        case version
        case totalExpenses = "total_expenses"
        case balances
        case payers
        case personalDebts = "personal_debts"
    }

    init(version: Int, totalExpenses: Int64, balances: [Balance], payers: [String: String], personalDebts: [PersonalDebt] = []) {
        self.version = version; self.totalExpenses = totalExpenses; self.balances = balances
        self.payers = payers; self.personalDebts = personalDebts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        totalExpenses = try c.decode(Int64.self, forKey: .totalExpenses)
        balances = try c.decode([Balance].self, forKey: .balances)
        payers = try c.decode([String: String].self, forKey: .payers)
        personalDebts = ((try? c.decodeIfPresent([PersonalDebt].self, forKey: .personalDebts)) ?? nil) ?? []
    }

    var memberBalances: [SettlementCalculator.MemberBalance] {
        balances.map {
            SettlementCalculator.MemberBalance(
                userId: $0.userId.lowercased(),
                contributed: $0.contributed,
                fairShare: $0.fairShare,
                personalShare: $0.personalShare
            )
        }
    }
}

/// Minimal DTO for creating a settlement. `id`, `settledAt`, `createdAt`
/// are filled server-side.
struct CreateSettlementInput: Encodable, Sendable {
    let shared_account_id: String
    let from_user_id: String
    let to_user_id: String
    let amount: Int64
    let currency: String
    let period_start: String
    let period_end: String
    let settled_by: String
    let linked_transfer_group_id: String?
    let note: String?
}
