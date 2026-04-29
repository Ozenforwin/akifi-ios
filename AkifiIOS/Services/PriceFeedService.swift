import Foundation
import Supabase

/// Thin wrapper around the `fetch-price` Supabase edge function.
/// The function reads from the `price_cache` table first (30-min
/// TTL); on miss it routes to CoinGecko (kind == .crypto) or Twelve
/// Data (everything else) and upserts the result back into the cache.
///
/// The Swift side never touches the providers directly — keeps the
/// API key server-side and lets the cache benefit from cross-user
/// hits. Failures (rate-limits, unknown ticker, missing key) come
/// back as `PriceFeedError` and the form falls back to manual entry.
final class PriceFeedService: Sendable {
    private let supabase = SupabaseManager.shared.client

    /// Pulls the latest price for the given ticker. The `currency`
    /// argument is the parent Asset's currency — passed through to
    /// the edge function so the response is in the same currency the
    /// holding is denominated in (no client-side FX guesswork).
    ///
    /// Returns the price as a `Decimal` (8-decimal precision preserved
    /// across JSON via the edge function returning a JSON number) and
    /// the ISO timestamp the price was either fetched at or last
    /// cached.
    func fetchPrice(
        ticker: String,
        kind: HoldingKind,
        currency: String
    ) async throws -> PriceFeedResult {
        let payload: [String: AnyJSON] = [
            "ticker": .string(ticker.trimmingCharacters(in: .whitespaces).uppercased()),
            "kind": .string(kind.rawValue),
            "currency": .string(currency.uppercased()),
        ]

        do {
            let response: FetchPriceResponse = try await supabase.functions.invoke(
                "fetch-price",
                options: .init(body: payload)
            )
            return PriceFeedResult(
                ticker: response.ticker,
                currency: response.currency,
                lastPrice: response.lastPrice,
                fetchedAt: response.fetchedAt,
                source: response.source,
                cached: response.cached ?? false
            )
        } catch let error as FunctionsError {
            // Surface the edge function's textual error so the form
            // can show the user *why* the pull failed (e.g. "TWELVE_
            // DATA_API_KEY not configured", "Unknown CoinGecko id").
            throw PriceFeedError.providerError(error.localizedDescription)
        } catch {
            throw PriceFeedError.transport(error.localizedDescription)
        }
    }
}

/// Successful result of a price pull. `cached == true` means the row
/// came from `price_cache` without hitting an upstream provider.
struct PriceFeedResult: Sendable {
    let ticker: String
    let currency: String
    let lastPrice: Decimal
    let fetchedAt: String
    let source: String
    let cached: Bool
}

/// Error surface for `PriceFeedService`. Form callers map both cases
/// onto the same in-context message; the distinction is kept so we
/// can split metrics later.
enum PriceFeedError: Error, LocalizedError {
    /// Provider returned a non-2xx response. The associated string is
    /// the message the edge function relayed.
    case providerError(String)
    /// Network / Functions-runtime error before we even got a
    /// response (offline, DNS, JWT expired etc.).
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .providerError(let msg): return msg
        case .transport(let msg): return msg
        }
    }
}

/// Wire format of the edge function's success response. We decode
/// `last_price` as `Decimal` to keep crypto satoshi-precision intact
/// (`Double` would clip on values like 0.00012345).
private struct FetchPriceResponse: Decodable {
    let ticker: String
    let currency: String
    let lastPrice: Decimal
    let fetchedAt: String
    let source: String
    let cached: Bool?

    enum CodingKeys: String, CodingKey {
        case ticker, currency, source, cached
        case lastPrice = "last_price"
        case fetchedAt = "fetched_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ticker = try c.decode(String.self, forKey: .ticker)
        currency = try c.decode(String.self, forKey: .currency)
        // PostgREST/Functions may serialise NUMERIC as either a JSON
        // number or a string — accept both.
        if let d = try? c.decode(Decimal.self, forKey: .lastPrice) {
            lastPrice = d
        } else if let s = try? c.decode(String.self, forKey: .lastPrice),
                  let d = Decimal(string: s) {
            lastPrice = d
        } else {
            lastPrice = 0
        }
        fetchedAt = try c.decode(String.self, forKey: .fetchedAt)
        source = try c.decode(String.self, forKey: .source)
        cached = try c.decodeIfPresent(Bool.self, forKey: .cached)
    }
}
