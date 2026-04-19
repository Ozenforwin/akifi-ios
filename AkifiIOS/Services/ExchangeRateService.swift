import Foundation

struct ExchangeRateResponse: Codable, Sendable {
    let result: String
    let rates: [String: Double]
}

actor ExchangeRateService {
    private let cacheKey = "cached_exchange_rates"
    private let cacheTimestampKey = "exchange_rates_timestamp"
    private let cacheDuration: TimeInterval = 3600 // 1 hour

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
}
