import Foundation

struct ExchangeRateResponse: Codable, Sendable {
    let result: String
    let rates: [String: Double]
}

/// APILayer Exchange Rates Data API response shape (historical + latest).
/// Uses `success`/`rates` (not `result`/`rates`) so a separate type.
struct APILayerRateResponse: Codable, Sendable {
    let success: Bool
    let base: String
    let date: String?
    let rates: [String: Double]
    let historical: Bool?
}

actor ExchangeRateService {
    private let cacheKey = "cached_exchange_rates"
    private let cacheTimestampKey = "exchange_rates_timestamp"
    private let cacheDuration: TimeInterval = 3600 // 1 hour
    private let historicalCacheKey = "cached_historical_exchange_rates"

    /// APILayer API key (Pro plan — 100 000 requests/month). Lives in
    /// Config/*.xcconfig via `EXCHANGE_RATE_API_KEY` so it is not
    /// committed. For local Debug builds Info.plist surfaces it.
    /// Used for historical rates in Phase 6 Reconciliation UI — never
    /// for the latest-rates hot path (that stays on free open.er-api.com
    /// so expiring the paid key doesn't break core app functionality).
    private var apiLayerKey: String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "EXCHANGE_RATE_API_KEY") as? String
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    /// Hard-coded fallback rates against USD (1 USD = X currency).
    /// Used when the public FX API is unreachable AND the on-disk cache is
    /// empty. Approximate rates as of 2026-04 — they only matter as a last
    /// resort; the API refreshes hourly via fetchRates().
    ///
    /// A code missing here is NOT coerced to 1.0 on the write path any
    /// more: `TransactionMath.convertForStorage` refuses the save with
    /// "no exchange rate" (M3 — 100 USD on a KZT account used to be stored
    /// as 100 ₸). Display paths still fall back to face value. Extend this
    /// table only for currencies users actually hold; never add 1:1 guesses.
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

    func fetchRates(base: String = "USD") async -> [String: Double] {
        // Check cache first
        if let cached = loadCachedRates(), !isCacheExpired() {
            return cached
        }

        // Offline: an expired cache still beats no rates at all — missing
        // rates make USD balances render 1:1 as base currency. Skip the
        // network attempts and their retry sleeps entirely.
        if await !NetworkMonitor.shared.isConnected {
            return loadCachedRates() ?? fallbackRates
        }

        // Fetch from API
        let urlString = "https://open.er-api.com/v6/latest/\(base)"
        guard let url = URL(string: urlString) else { return fallbackRates }

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
                    saveCachedRates(decoded.rates)
                    return decoded.rates
                }
            } catch {
                if attempt == 1 { break }
            }
        }

        return loadCachedRates() ?? fallbackRates
    }

    private func loadCachedRates() -> [String: Double]? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let rates = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return nil
        }
        return rates
    }

    private func saveCachedRates(_ rates: [String: Double]) {
        if let data = try? JSONEncoder().encode(rates) {
            UserDefaults.standard.set(data, forKey: cacheKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheTimestampKey)
        }
    }

    private func isCacheExpired() -> Bool {
        let timestamp = UserDefaults.standard.double(forKey: cacheTimestampKey)
        guard timestamp > 0 else { return true }
        return Date().timeIntervalSince1970 - timestamp > cacheDuration
    }

    // MARK: - Historical rates (APILayer)

    /// Fetch the historical rate `from → to` for a specific date. Cached
    /// permanently per `(from, to, date)` — historical rates never change.
    /// Returns `nil` on API key missing / network error; the caller should
    /// surface an "approximate rate" warning and let the user opt in
    /// (Phase 6 Reconciliation UI).
    ///
    /// Endpoint: `https://api.apilayer.com/exchangerates_data/{YYYY-MM-DD}`
    /// Auth: `apikey: <EXCHANGE_RATE_API_KEY>` header.
    func fetchHistoricalRate(from: String, to: String, date: Date) async -> Double? {
        let dateStr = Self.historicalDateKey(for: date)
        let cacheKey = "\(from.uppercased())-\(to.uppercased())-\(dateStr)"

        // Persistent cache: historical quotes never change.
        if let cached = loadHistoricalCache()[cacheKey] {
            return cached
        }

        guard let key = apiLayerKey else { return nil }

        let urlString = "https://api.apilayer.com/exchangerates_data/\(dateStr)?base=\(from.uppercased())&symbols=\(to.uppercased())"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "apikey")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let decoded = try JSONDecoder().decode(APILayerRateResponse.self, from: data)
            guard decoded.success, let rate = decoded.rates[to.uppercased()] else {
                return nil
            }
            saveHistoricalCache(key: cacheKey, rate: rate)
            return rate
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
