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
    /// empty. MUST cover every CurrencyCode in the app — a missing entry
    /// silently coerces to 1.0 in CurrencyManager.crossConvert and produces
    /// catastrophic conversions (e.g. 2 000 000 VND → 26 315 USD when
    /// rates["VND"] defaults to 1.0).
    /// Approximate rates as of 2026-04 — they only matter as a last resort;
    /// the API refreshes hourly via fetchRates().
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
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withFullDate]
        let dateStr = df.string(from: date)
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
                let df = ISO8601DateFormatter()
                df.formatOptions = [.withFullDate]
                out["\(pair.from.uppercased())-\(pair.to.uppercased())-\(df.string(from: pair.date))"] = rate
            }
        }
        return out
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
