import Foundation
import Supabase

final class BudgetRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    func fetchAll() async throws -> [Budget] {
        try await SupabasePaging.all("budgets") { count in
            supabase
                .from("budgets")
                .select(count: count)
                .eq("is_active", value: true)
                .order("created_at", ascending: false)
        }
    }

    func create(_ input: CreateBudgetInput) async throws -> Budget {
        try await supabase
            .from("budgets")
            .insert(input)
            .select()
            .single()
            .execute()
            .value
    }

    func update(id: String, _ input: UpdateBudgetInput) async throws {
        try await supabase
            .from("budgets")
            .update(input)
            .eq("id", value: id)
            .execute()
    }

    func delete(id: String) async throws {
        try await supabase
            .from("budgets")
            .update(["is_active": false])
            .eq("id", value: id)
            .execute()
    }

    /// Server-computed metrics for every active budget the user owns or is
    /// a member of (RPC `get_budget_metrics`, migration 20261117130003).
    /// The server sees every member's rows, so a shared budget gets the same
    /// numbers on every phone — unlike `BudgetMath` over the RLS-filtered
    /// transaction list. `today` is the user's local "yyyy-MM-dd".
    func fetchMetrics(today: String, timeZone: String) async throws -> ServerBudgetMetricsResponse {
        // bounded-fetch: the RPC returns one jsonb value, not a row set — max-rows cannot apply.
        try await supabase
            .rpc("get_budget_metrics", params: BudgetMetricsParams(p_today: today, p_tz: timeZone))
            .execute()
            .value
    }
}

private struct BudgetMetricsParams: Encodable, Sendable {
    let p_today: String
    let p_tz: String
}

/// Response of `get_budget_metrics`.
struct ServerBudgetMetricsResponse: Codable, Sendable, Equatable {
    let version: Int
    let today: String
    let budgets: [ServerBudgetMetrics]
}

/// One budget as the server computed it. Amounts are minor units of the
/// budget's `currency`. Decoding is tolerant (defaults for anything but the
/// core numbers) so a newer server version can add fields without breaking
/// shipped clients.
struct ServerBudgetMetrics: Codable, Sendable, Equatable {
    struct MemberSpend: Codable, Sendable, Equatable {
        let userId: String
        let spent: Int64
        let txCount: Int

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case spent
            case txCount = "tx_count"
        }
    }

    struct CategoryRef: Codable, Sendable, Equatable {
        let id: String
        let name: String
        let icon: String?
    }

    let budgetId: String
    let name: String?
    let currency: String
    let periodType: String
    /// "yyyy-MM-dd", inclusive.
    let periodStart: String
    let periodEnd: String
    let totalDays: Int
    let elapsedDays: Int
    let remainingDays: Int
    let limit: Int64
    let carryIn: Int64
    let effectiveLimit: Int64
    let spent: Int64
    let spentToday: Int64
    let remaining: Int64
    let subscriptionCommitted: Int64
    let subscriptionCount: Int
    let freeRemaining: Int64
    let safeToSpendDaily: Int64
    let utilization: Int
    let paceRatio: Double
    let txCount: Int
    let memberIds: [String]
    let byMember: [MemberSpend]
    let categories: [CategoryRef]
    /// Units per 1 USD for every currency the server converted with.
    let fx: [String: Double]
    let fxMissing: [String]

    enum CodingKeys: String, CodingKey {
        case budgetId = "budget_id"
        case name, currency
        case periodType = "period_type"
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case totalDays = "total_days"
        case elapsedDays = "elapsed_days"
        case remainingDays = "remaining_days"
        case limit
        case carryIn = "carry_in"
        case effectiveLimit = "effective_limit"
        case spent
        case spentToday = "spent_today"
        case remaining
        case subscriptionCommitted = "subscription_committed"
        case subscriptionCount = "subscription_count"
        case freeRemaining = "free_remaining"
        case safeToSpendDaily = "safe_to_spend_daily"
        case utilization
        case paceRatio = "pace_ratio"
        case txCount = "tx_count"
        case memberIds = "member_ids"
        case byMember = "by_member"
        case categories, fx
        case fxMissing = "fx_missing"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        budgetId = try c.decode(String.self, forKey: .budgetId).lowercased()
        name = try c.decodeIfPresent(String.self, forKey: .name)
        currency = try c.decode(String.self, forKey: .currency).uppercased()
        periodType = try c.decodeIfPresent(String.self, forKey: .periodType) ?? ""
        periodStart = try c.decode(String.self, forKey: .periodStart)
        periodEnd = try c.decode(String.self, forKey: .periodEnd)
        totalDays = try c.decode(Int.self, forKey: .totalDays)
        elapsedDays = try c.decode(Int.self, forKey: .elapsedDays)
        remainingDays = try c.decode(Int.self, forKey: .remainingDays)
        limit = try c.decode(Int64.self, forKey: .limit)
        carryIn = try c.decodeIfPresent(Int64.self, forKey: .carryIn) ?? 0
        effectiveLimit = try c.decode(Int64.self, forKey: .effectiveLimit)
        spent = try c.decode(Int64.self, forKey: .spent)
        spentToday = try c.decodeIfPresent(Int64.self, forKey: .spentToday) ?? 0
        remaining = try c.decode(Int64.self, forKey: .remaining)
        subscriptionCommitted = try c.decodeIfPresent(Int64.self, forKey: .subscriptionCommitted) ?? 0
        subscriptionCount = try c.decodeIfPresent(Int.self, forKey: .subscriptionCount) ?? 0
        freeRemaining = try c.decodeIfPresent(Int64.self, forKey: .freeRemaining) ?? 0
        safeToSpendDaily = try c.decode(Int64.self, forKey: .safeToSpendDaily)
        utilization = try c.decode(Int.self, forKey: .utilization)
        paceRatio = try c.decodeIfPresent(Double.self, forKey: .paceRatio) ?? 0
        txCount = try c.decodeIfPresent(Int.self, forKey: .txCount) ?? 0
        memberIds = (try c.decodeIfPresent([String].self, forKey: .memberIds) ?? []).map { $0.lowercased() }
        byMember = try c.decodeIfPresent([MemberSpend].self, forKey: .byMember) ?? []
        categories = try c.decodeIfPresent([CategoryRef].self, forKey: .categories) ?? []
        fx = try c.decodeIfPresent([String: Double].self, forKey: .fx) ?? [:]
        fxMissing = try c.decodeIfPresent([String].self, forKey: .fxMissing) ?? []
    }

    /// The window as local-midnight dates (same convention as
    /// `BudgetMath.currentPeriod`).
    var period: (start: Date, end: Date)? {
        let df = AppDateFormatters.isoDate
        guard let s = df.date(from: periodStart), let e = df.date(from: periodEnd) else { return nil }
        return (s, e)
    }
}

struct CreateBudgetInput: Encodable, Sendable {
    let user_id: String
    let name: String?
    let description: String?
    let amount: Decimal
    let period_type: String
    let category_ids: [String]
    let account_ids: [String]?
    let rollover_enabled: Bool
    let alert_thresholds: [Int]
    let budget_type: String
    let custom_start_date: String?
    let custom_end_date: String?
    /// ISO 4217 (uppercase). NOT NULL on the server since migration
    /// 20261117130002; when omitted the server fills the owner's currency.
    let currency: String?
}

struct UpdateBudgetInput: Encodable, Sendable {
    var name: String?
    var description: String?
    var amount: Decimal?
    var period_type: String?
    var category_ids: [String]?
    var account_ids: [String]?
    var rollover_enabled: Bool?
    var alert_thresholds: [Int]?
    var budget_type: String?
    var custom_start_date: String?
    var custom_end_date: String?
    var currency: String?
}
