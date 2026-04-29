import Foundation
import Supabase

/// CRUD wrapper around the `investment_holdings` table. RLS enforces
/// own-only access server-side (see migration
/// `20260429120000_investment_holdings.sql`), so reads don't need a
/// client-side user-id filter.
///
/// Note: the AFTER STATEMENT trigger
/// `recompute_asset_value_on_holding_change` updates `assets.current_value`
/// for the affected asset(s) on every insert/update/delete here. Callers
/// should refetch the parent `Asset` after CRUD to pick up the new value
/// in the UI (`PortfolioViewModel` does this automatically).
final class InvestmentHoldingRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    /// All holdings for the current user, newest-first. RLS filters
    /// implicitly. The list is small in practice (a typical retail
    /// investor has <30 positions), so we don't paginate.
    func fetchAll() async throws -> [InvestmentHolding] {
        try await supabase
            .from("investment_holdings")
            .select()
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    /// Holdings inside a specific Asset — used by
    /// `InvestmentHoldingsListView` embedded in `AssetFormView`.
    func fetchForAsset(_ assetId: String) async throws -> [InvestmentHolding] {
        try await supabase
            .from("investment_holdings")
            .select()
            .eq("asset_id", value: assetId)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func create(_ input: CreateHoldingInput) async throws -> InvestmentHolding {
        try await supabase
            .from("investment_holdings")
            .insert(input)
            .select()
            .single()
            .execute()
            .value
    }

    func update(id: String, _ input: UpdateHoldingInput) async throws {
        try await supabase
            .from("investment_holdings")
            .update(input)
            .eq("id", value: id)
            .execute()
    }

    /// Update only the price fields — used by the "Pull current price"
    /// button and `PortfolioViewModel.refreshAllPrices()`. Cheaper than
    /// a full update payload, lets PostgREST diff fewer columns.
    func updatePrice(id: String, lastPrice: Decimal, lastPriceDate: String) async throws {
        let payload = UpdatePriceInput(
            last_price: NSDecimalNumber(decimal: lastPrice).stringValue,
            last_price_date: lastPriceDate
        )
        try await supabase
            .from("investment_holdings")
            .update(payload)
            .eq("id", value: id)
            .execute()
    }

    func delete(id: String) async throws {
        try await supabase
            .from("investment_holdings")
            .delete()
            .eq("id", value: id)
            .execute()
    }
}

/// Insert payload. `user_id` is filled from `auth.uid()` client-side via
/// `SupabaseManager.currentUserId()`; the DB defaults to `auth.uid()`
/// regardless (belt-and-suspenders).
///
/// `quantity` and `last_price` are sent as strings so we don't lose
/// precision on round-trip through `JSONEncoder` (which serialises
/// `Decimal` via `Double` and drops the 8th fractional digit).
struct CreateHoldingInput: Encodable, Sendable {
    let user_id: String
    let asset_id: String
    let ticker: String
    let kind: String
    let quantity: String
    let cost_basis: Int64
    let last_price: String
    let last_price_date: String
    let notes: String?

    init(userId: String, assetId: String, ticker: String, kind: HoldingKind,
         quantity: Decimal, costBasis: Int64, lastPrice: Decimal,
         lastPriceDate: String, notes: String?) {
        self.user_id = userId
        self.asset_id = assetId
        self.ticker = ticker
        self.kind = kind.rawValue
        self.quantity = NSDecimalNumber(decimal: quantity).stringValue
        self.cost_basis = costBasis
        self.last_price = NSDecimalNumber(decimal: lastPrice).stringValue
        self.last_price_date = lastPriceDate
        self.notes = notes
    }
}

struct UpdateHoldingInput: Encodable, Sendable {
    let ticker: String?
    let kind: String?
    let quantity: String?
    let cost_basis: Int64?
    let last_price: String?
    let last_price_date: String?
    let notes: String?

    init(ticker: String? = nil, kind: HoldingKind? = nil,
         quantity: Decimal? = nil, costBasis: Int64? = nil,
         lastPrice: Decimal? = nil, lastPriceDate: String? = nil,
         notes: String? = nil) {
        self.ticker = ticker
        self.kind = kind?.rawValue
        self.quantity = quantity.map { NSDecimalNumber(decimal: $0).stringValue }
        self.cost_basis = costBasis
        self.last_price = lastPrice.map { NSDecimalNumber(decimal: $0).stringValue }
        self.last_price_date = lastPriceDate
        self.notes = notes
    }
}

private struct UpdatePriceInput: Encodable, Sendable {
    let last_price: String
    let last_price_date: String
}
