import Foundation
import Supabase

struct ExchangeRateResponse: Codable, Sendable {
    let result: String
    let rates: [String: Double]
}

/// A USD-pivoted FX table (`rates[X]` = units of X per 1 USD) together with
/// WHEN each quote was obtained from a real source.
///
/// Display may use any rate — a stale or hard-coded one beats rendering a
/// USD balance 1:1 as roubles. A WRITE may not (M5): a rate frozen into
/// `amount_native` stays wrong forever, and the old offline path stored
/// 100 USD on a RUB account at the April fallback 92.5 instead of 82.57
/// (+993 ₽ for good). `writableRates` keeps only codes quoted by the
/// network or the server `fx_rates` table within `maxWriteAge`; the
/// hard-coded fallback table carries no quote time and is never writable.
struct FXRateSnapshot: Sendable, Equatable {
    /// Everything we have, for display.
    var rates: [String: Double]
    /// Code → when that quote came from the network / server. Codes without
    /// an entry (fallback table) are display-only.
    var quotedAt: [String: Date]

    static let empty = FXRateSnapshot(rates: [:], quotedAt: [:])

    /// Oldest quote a write may freeze into `amount_native`.
    static let maxWriteAge: TimeInterval = 48 * 3600

    /// The subset of `rates` a write may use at `now`.
    func writableRates(now: Date = Date()) -> [String: Double] {
        var out: [String: Double] = [:]
        for (code, rate) in rates where rate > 0 && rate.isFinite {
            guard let at = quotedAt[code] else { continue }
            let age = now.timeIntervalSince(at)
            // A quote "from the future" (clock skew) counts as fresh.
            if age <= Self.maxWriteAge { out[code] = rate }
        }
        return out
    }

    /// Rows of `public.fx_rates` (code, per_usd, updated_at). Each code is
    /// stamped with its own `updated_at` — a row the refresh job skipped
    /// ages out on its own.
    static func fromServer(_ rows: [ServerFXRateRow]) -> FXRateSnapshot {
        var rates: [String: Double] = [:]
        var quotedAt: [String: Date] = [:]
        for row in rows {
            let code = row.code.uppercased()
            guard row.perUsd > 0, row.perUsd.isFinite else { continue }
            rates[code] = row.perUsd
            if let at = AppDateFormatters.parseTimestamp(row.updatedAt) {
                quotedAt[code] = at
            }
        }
        return FXRateSnapshot(rates: rates, quotedAt: quotedAt)
    }

    /// A full network table, every code quoted at `at`.
    static func fromNetwork(_ rates: [String: Double], at: Date) -> FXRateSnapshot {
        FXRateSnapshot(rates: rates, quotedAt: rates.mapValues { _ in at })
    }

    /// Hard-coded table: display only.
    static func fallback(_ rates: [String: Double]) -> FXRateSnapshot {
        FXRateSnapshot(rates: rates, quotedAt: [:])
    }
}

/// One row of `public.fx_rates`.
struct ServerFXRateRow: Decodable, Sendable, Identifiable {
    let code: String
    let perUsd: Double
    let updatedAt: String

    var id: String { code }

    enum CodingKeys: String, CodingKey {
        case code
        case perUsd = "per_usd"
        case updatedAt = "updated_at"
    }
}

actor ExchangeRateService {
    private let cacheKey = "cached_exchange_rates"
    private let cacheTimestampKey = "exchange_rates_timestamp"
    /// Per-code quote times of the cached table (seconds since 1970). A
    /// cache written before this key existed came from a network fetch at
    /// `cacheTimestampKey`, which is used for every code then.
    private let cacheQuotedAtKey = "cached_exchange_rates_quoted_at"
    private let cacheDuration: TimeInterval = 3600 // 1 hour
    private let historicalCacheKey = "cached_historical_exchange_rates"

    /// Hard-coded fallback rates against USD (1 USD = X currency), shown
    /// when the public FX API, the server table and the on-disk cache are
    /// all unavailable. DISPLAY ONLY: `FXRateSnapshot.fallback` gives them
    /// no quote time, so no write ever converts with them (M5).
    ///
    /// Display paths fall back to face value for a code missing here.
    /// Never add 1:1 guesses.
    private let fallbackRates: [String: Double] = [
        "USD": 1.0,
        "RUB": 92.5,
        "EUR": 0.92,
        "GBP": 0.79,
        "CNY": 7.24,
        "JPY": 154.5,
        "VND": 25_400,
        "THB": 36.5,
        "IDR": 16_300
    ]

    func fetchRates(base: String = "USD") async -> FXRateSnapshot {
        // Check cache first
        if let cached = loadCachedSnapshot(), !isCacheExpired() {
            return cached
        }

        // Offline: an expired cache still beats no rates at all for display
        // (missing rates make USD balances render 1:1 as base currency);
        // its quote times keep writes honest. Skip the network attempts and
        // their retry sleeps entirely.
        if await !NetworkMonitor.shared.isConnected {
            return loadCachedSnapshot() ?? .fallback(fallbackRates)
        }

        if let network = await fetchNetworkRates(base: base) {
            saveCachedSnapshot(network)
            return network
        }

        // The public API is down but our backend may not be: its fx_rates
        // table (refreshed hourly by `refresh-fx-rates`) is a real quote.
        if let server = await fetchServerRates() {
            let merged = merge(server, over: loadCachedSnapshot())
            saveCachedSnapshot(merged)
            return merged
        }

        return loadCachedSnapshot() ?? .fallback(fallbackRates)
    }

    private func fetchNetworkRates(base: String) async -> FXRateSnapshot? {
        let urlString = "https://open.er-api.com/v6/latest/\(base)"
        guard let url = URL(string: urlString) else { return nil }

        // Retry with exponential backoff (2 attempts max)
        for attempt in 0..<2 {
            do {
                if attempt > 0 {
                    try await Task.sleep(for: .seconds(Double(attempt) * 2))
                }
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else { continue }

                let decoded = try JSONDecoder().decode(ExchangeRateResponse.self, from: data)
                if decoded.result == "success" {
                    return .fromNetwork(decoded.rates, at: Date())
                }
            } catch {
                if attempt == 1 { break }
            }
        }
        return nil
    }

    /// `public.fx_rates` — readable by any signed-in user. Nil when signed
    /// out, offline or the read fails.
    private func fetchServerRates() async -> FXRateSnapshot? {
        let client = SupabaseManager.shared.client
        do {
            let rows: [ServerFXRateRow] = try await SupabasePaging.all("fx_rates", tiebreak: ["code"]) { count in
                client
                    .from("fx_rates")
                    .select("code, per_usd, updated_at", count: count)
            }
            guard !rows.isEmpty else { return nil }
            return .fromServer(rows)
        } catch {
            AppLogger.data.debug("fx_rates read failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// `top` wins per code; codes only `bottom` has keep their own quote time.
    private func merge(_ top: FXRateSnapshot, over bottom: FXRateSnapshot?) -> FXRateSnapshot {
        guard var out = bottom else { return top }
        for (code, rate) in top.rates {
            out.rates[code] = rate
            out.quotedAt[code] = top.quotedAt[code]
        }
        return out
    }

    private func loadCachedSnapshot() -> FXRateSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let rates = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return nil
        }
        if let quotedData = UserDefaults.standard.data(forKey: cacheQuotedAtKey),
           let stamps = try? JSONDecoder().decode([String: Double].self, from: quotedData) {
            return FXRateSnapshot(
                rates: rates,
                quotedAt: stamps.mapValues { Date(timeIntervalSince1970: $0) }
            )
        }
        // Pre-M5 cache: only ever written after a successful network fetch.
        let timestamp = UserDefaults.standard.double(forKey: cacheTimestampKey)
        guard timestamp > 0 else { return .fallback(rates) }
        return .fromNetwork(rates, at: Date(timeIntervalSince1970: timestamp))
    }

    private func saveCachedSnapshot(_ snapshot: FXRateSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot.rates),
              let stamps = try? JSONEncoder().encode(snapshot.quotedAt.mapValues(\.timeIntervalSince1970)) else {
            return
        }
        // Same slot and shape as before — AppViewModel reads it for the
        // instant start (display only).
        UserDefaults.standard.set(data, forKey: cacheKey)
        UserDefaults.standard.set(stamps, forKey: cacheQuotedAtKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheTimestampKey)
    }

    private func isCacheExpired() -> Bool {
        let timestamp = UserDefaults.standard.double(forKey: cacheTimestampKey)
        guard timestamp > 0 else { return true }
        return Date().timeIntervalSince1970 - timestamp > cacheDuration
    }

    // MARK: - Historical rates (edge function `fx-historical`)

    /// Fetch the historical rate `from → to` for the user's calendar day
    /// `date` (local midnight). See `fetchHistoricalRate(from:to:day:)`.
    func fetchHistoricalRate(from: String, to: String, date: Date) async -> Double? {
        await fetchHistoricalRate(from: from, to: to, day: Self.historicalDateKey(for: date))
    }

    /// Historical rate `from → to` (units of `to` per 1 `from`) on `day`
    /// ("YYYY-MM-DD"). Cached permanently per `(from, to, day)` —
    /// historical quotes never change. `nil` when unavailable (offline,
    /// signed out, any 4xx/5xx); the caller surfaces an "approximate rate"
    /// warning (Phase 6 Reconciliation UI).
    ///
    /// S4: the paid APILayer key used to ship in every IPA (Info.plist). The
    /// `fx-historical` edge function now holds it as a secret and caches
    /// answers server-side; the app only sends the user's session.
    func fetchHistoricalRate(from: String, to: String, day: String) async -> Double? {
        let src = from.uppercased()
        let dst = to.uppercased()
        let dayKey = String(day.prefix(10))
        let cacheKey = "\(src)-\(dst)-\(dayKey)"

        // Persistent cache: historical quotes never change.
        if let cached = loadHistoricalCache()[cacheKey] {
            return cached
        }
        if src == dst { return 1 }

        struct Response: Decodable { let rate: Double }
        let body: [String: String] = ["from": src, "to": dst, "date": dayKey]
        do {
            let response: Response = try await SupabaseManager.shared.client.functions.invoke(
                "fx-historical",
                options: .init(body: body)
            )
            guard response.rate > 0, response.rate.isFinite else { return nil }
            saveHistoricalCache(key: cacheKey, rate: response.rate)
            return response.rate
        } catch {
            return nil
        }
    }

    /// Batch fetch historical rates for multiple (from, date) pairs — used
    /// by the Reconciliation UI when opening a screen with many rows in
    /// the same foreign currency. Returns a dictionary keyed by
    /// `"FROM-TO-YYYY-MM-DD"` matching `fetchHistoricalRate`'s cache key.
    func fetchHistoricalRates(
        pairs: [(from: String, to: String, date: Date)]
    ) async -> [String: Double] {
        var out: [String: Double] = [:]
        for pair in pairs {
            if let rate = await fetchHistoricalRate(from: pair.from, to: pair.to, date: pair.date) {
                out["\(pair.from.uppercased())-\(pair.to.uppercased())-\(Self.historicalDateKey(for: pair.date))"] = rate
            }
        }
        return out
    }

    /// The calendar day the user means by `date`, as "YYYY-MM-DD".
    ///
    /// Callers pass a transaction's day parsed as LOCAL midnight. The old
    /// `ISO8601DateFormatter` formats in GMT, so for a UTC+7 user local
    /// midnight of the 17th became "…-16" and the quote was for the
    /// previous day. Gregorian digits regardless of the device calendar.
    static func historicalDateKey(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func loadHistoricalCache() -> [String: Double] {
        guard let data = UserDefaults.standard.data(forKey: historicalCacheKey),
              let rates = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        return rates
    }

    private func saveHistoricalCache(key: String, rate: Double) {
        var cache = loadHistoricalCache()
        cache[key] = rate
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: historicalCacheKey)
        }
    }
}
