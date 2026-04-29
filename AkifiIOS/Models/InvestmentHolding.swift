import Foundation

/// A single investment position inside an `Asset` of category
/// `investment` or `crypto`. Many holdings collapse into the parent
/// `Asset.currentValue` via the `recompute_asset_value_on_holding_change`
/// AFTER STATEMENT trigger — `NetWorthCalculator` keeps reading the
/// pre-aggregated `Asset.currentValue` and never sees holdings directly.
///
/// Money fields:
/// * `costBasis` — minor units (kopecks) of the parent Asset's currency.
/// * `quantity` and `lastPrice` are `Decimal` to preserve precision for
///   crypto satoshis and 8-decimal feeds. Server stores `NUMERIC(28,8)`
///   and `NUMERIC(20,8)` respectively; PostgREST may serialise them as
///   strings, so the decoder handles both.
struct InvestmentHolding: Codable, Sendable, Identifiable {
    let id: String
    let userId: String
    let assetId: String
    var ticker: String
    var kind: HoldingKind
    var quantity: Decimal
    /// Average buy price × quantity, in minor units of `Asset.currency`.
    var costBasis: Int64
    /// Latest price per unit, in `Asset.currency`. Updated either manually
    /// or via `PriceFeedService` (Sprint 3).
    var lastPrice: Decimal
    /// "yyyy-MM-dd". Reused parser: `NetWorthSnapshotRepository.dateFormatter`.
    var lastPriceDate: String
    var notes: String?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case assetId = "asset_id"
        case ticker, kind, quantity, notes
        case costBasis = "cost_basis"
        case lastPrice = "last_price"
        case lastPriceDate = "last_price_date"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(id: String, userId: String, assetId: String, ticker: String,
         kind: HoldingKind, quantity: Decimal, costBasis: Int64,
         lastPrice: Decimal, lastPriceDate: String, notes: String? = nil,
         createdAt: String? = nil, updatedAt: String? = nil) {
        self.id = id
        self.userId = userId
        self.assetId = assetId
        self.ticker = ticker
        self.kind = kind
        self.quantity = quantity
        self.costBasis = costBasis
        self.lastPrice = lastPrice
        self.lastPriceDate = lastPriceDate
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userId = try c.decode(String.self, forKey: .userId)
        assetId = try c.decode(String.self, forKey: .assetId)
        ticker = try c.decode(String.self, forKey: .ticker)
        kind = try c.decode(HoldingKind.self, forKey: .kind)
        quantity = try Self.decodeDecimal(c, forKey: .quantity)
        if let i = try? c.decode(Int64.self, forKey: .costBasis) {
            costBasis = i
        } else if let s = try? c.decode(String.self, forKey: .costBasis), let v = Int64(s) {
            costBasis = v
        } else {
            costBasis = 0
        }
        lastPrice = try Self.decodeDecimal(c, forKey: .lastPrice)
        lastPriceDate = try c.decode(String.self, forKey: .lastPriceDate)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(userId, forKey: .userId)
        try c.encode(assetId, forKey: .assetId)
        try c.encode(ticker, forKey: .ticker)
        try c.encode(kind, forKey: .kind)
        try c.encode(NSDecimalNumber(decimal: quantity).stringValue, forKey: .quantity)
        try c.encode(costBasis, forKey: .costBasis)
        try c.encode(NSDecimalNumber(decimal: lastPrice).stringValue, forKey: .lastPrice)
        try c.encode(lastPriceDate, forKey: .lastPriceDate)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }

    /// PostgREST returns `NUMERIC` either as a JSON number or string —
    /// accept both rather than assuming.
    private static func decodeDecimal(
        _ c: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Decimal {
        if let d = try? c.decode(Decimal.self, forKey: key) {
            return d
        }
        if let s = try? c.decode(String.self, forKey: key), let d = Decimal(string: s) {
            return d
        }
        return 0
    }

    /// Current market value of this holding in the parent Asset's currency,
    /// in minor units (kopecks). `quantity × lastPrice × 100` rounded.
    var currentValueMinor: Int64 {
        var product = quantity * lastPrice * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &product, 0, .plain)
        return Int64(truncating: rounded as NSDecimalNumber)
    }

    /// True when `lastPriceDate` is more than 30 days behind today —
    /// drives the "stale" badge in the UI.
    func isStale(asOf today: Date = Date()) -> Bool {
        guard let d = NetWorthSnapshotRepository.dateFormatter.date(from: lastPriceDate) else {
            return true
        }
        let days = Calendar(identifier: .gregorian).dateComponents([.day], from: d, to: today).day ?? 0
        return days > 30
    }
}

/// Mirrors the DB CHECK constraint on `investment_holdings.kind`.
/// Order matches typical retail portfolio composition for stable
/// allocation chart sorting.
enum HoldingKind: String, Codable, CaseIterable, Sendable, Hashable {
    case stock
    case etf
    case bond
    case crypto
    case metal
    case fund
    case other

    /// SF Symbol for chips and pickers.
    var symbol: String {
        switch self {
        case .stock:  return "chart.line.uptrend.xyaxis"
        case .etf:    return "square.stack.3d.up.fill"
        case .bond:   return "doc.text.fill"
        case .crypto: return "bitcoinsign.circle.fill"
        case .metal:  return "circle.hexagongrid.fill"
        case .fund:   return "building.columns.fill"
        case .other:  return "questionmark.circle.fill"
        }
    }

    /// Default hex color per kind. Used for allocation pie chart slices
    /// when the user hasn't tagged the asset with their own color.
    var defaultHex: String {
        switch self {
        case .stock:  return "#60A5FA"
        case .etf:    return "#4ADE80"
        case .bond:   return "#A78BFA"
        case .crypto: return "#FBBF24"
        case .metal:  return "#94A3B8"
        case .fund:   return "#F472B6"
        case .other:  return "#9CA3AF"
        }
    }

    /// Localised user-facing title (RU/EN/ES via xcstrings).
    var localizedTitle: String {
        switch self {
        case .stock:  return String(localized: "holding.kind.stock")
        case .etf:    return String(localized: "holding.kind.etf")
        case .bond:   return String(localized: "holding.kind.bond")
        case .crypto: return String(localized: "holding.kind.crypto")
        case .metal:  return String(localized: "holding.kind.metal")
        case .fund:   return String(localized: "holding.kind.fund")
        case .other:  return String(localized: "holding.kind.other")
        }
    }

    /// Whether `PriceFeedService` (Sprint 3) can fetch a quote for this kind.
    /// Stocks/ETFs/bonds/funds → Twelve Data; crypto → CoinGecko.
    /// Metals and "other" stay manual until a feed is added.
    var supportsAutoPrice: Bool {
        switch self {
        case .stock, .etf, .bond, .fund, .crypto: return true
        case .metal, .other: return false
        }
    }
}
