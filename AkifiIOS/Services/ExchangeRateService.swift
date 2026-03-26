import Foundation

struct ExchangeRateResponse: Codable, Sendable {
    let result: String
    let rates: [String: Double]
}

actor ExchangeRateService {
    private let cacheKey = "cached_exchange_rates"
    private let cacheTimestampKey = "exchange_rates_timestamp"
    private let cacheDuration: TimeInterval = 3600 // 1 hour

    private let fallbackRates: [String: Double] = [
        "USD": 1.0,
        "RUB": 92.5,
        "EUR": 0.92,
        "GBP": 0.79,
        "CNY": 7.24,
        "JPY": 154.5
    ]

    func fetchRates(base: String = "USD") async -> [String: Double] {
        // Check cache first
        if let cached = loadCachedRates(), !isCacheExpired() {
            return cached
        }

        // Fetch from API
        let urlString = "https://open.er-api.com/v6/latest/\(base)"
        guard let url = URL(string: urlString) else { return fallbackRates }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return loadCachedRates() ?? fallbackRates
            }

            let decoded = try JSONDecoder().decode(ExchangeRateResponse.self, from: data)
            if decoded.result == "success" {
                saveCachedRates(decoded.rates)
                return decoded.rates
            }
        } catch {
            // Fall through to cached or fallback
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
