import Foundation
import Observation

/// User-curated list of "active" currencies shown inline in transaction,
/// account and budget forms.
///
/// ## Why this exists
/// Before the ISO-catalog migration, the app shipped a hard-coded enum of
/// 9 currencies (`RUB, USD, EUR, VND, THB, IDR, KZT, GEL, TRY`) and forms
/// rendered an inline `Menu` picker — fast, one-tap. After the migration
/// to ~170 ISO codes, every form switched to a `sheet`-based searchable
/// picker, which is great for breadth but slow for daily use (open sheet,
/// scroll, dismiss — every time you log a coffee).
///
/// `UserCurrencyPreferences` re-introduces the inline picker by letting
/// each user pick *their* short list, while the full catalog stays one
/// tap away as an "All currencies…" escape hatch.
///
/// ## Persistence
/// Stored in `UserDefaults` as a comma-joined uppercase string (same shape
/// the rest of the app uses for ID lists, e.g. `excludedAccountIds` in
/// `PortfolioChartView`). Empty / missing → falls back to the legacy 9
/// codes so first-launch UX matches the old hard-coded enum exactly.
///
/// ## Concurrency
/// `@Observable @MainActor` — exposed as a singleton (`shared`) and read
/// from SwiftUI views; no off-main mutation is expected.
@Observable
@MainActor
final class UserCurrencyPreferences {

    // MARK: - Defaults & storage key

    /// The 9 codes that used to be the closed `enum CurrencyCode`. Reusing
    /// them as the first-launch default keeps the migration invisible to
    /// existing users — they see exactly the same inline list they had
    /// before, until they choose to customize it.
    static let defaultCodes: [String] = [
        "RUB", "USD", "EUR", "VND", "THB", "IDR", "KZT", "GEL", "TRY",
    ]

    /// UserDefaults key. Single canonical name to avoid drift between
    /// reads and writes.
    static let storageKey: String = "user.activeCurrencies"

    // MARK: - Singleton (production)

    /// Shared production instance backed by `UserDefaults.standard`.
    /// Tests should construct their own instance with a private suite —
    /// see `UserCurrencyPreferencesTests`.
    static let shared = UserCurrencyPreferences()

    // MARK: - Storage backing

    private let defaults: UserDefaults

    /// Hidden raw store. Mutations go through the public `activeCodes`
    /// setter so persistence + observation stay in sync.
    private var _activeCodes: [String]

    // MARK: - Init

    /// - Parameter defaults: the `UserDefaults` instance to read/write.
    ///   Pass a private suite in tests to isolate from production storage.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self._activeCodes = Self.load(from: defaults)
    }

    // MARK: - Public API

    /// Currently-active currency codes, in user-defined order. Always
    /// uppercase, deduplicated. Setting persists to `UserDefaults`.
    /// Setting an empty array clears the key and resets to defaults.
    var activeCodes: [String] {
        get { _activeCodes }
        set {
            let normalized = Self.normalize(newValue)
            if normalized.isEmpty {
                // Empty input → fall back to defaults rather than hide
                // the picker. The Manage screen enforces "at least one"
                // at the UI layer; this is the belt-and-braces guard
                // for any other caller.
                _activeCodes = Self.defaultCodes
                defaults.removeObject(forKey: Self.storageKey)
            } else {
                _activeCodes = normalized
                defaults.set(normalized.joined(separator: ","), forKey: Self.storageKey)
            }
        }
    }

    /// Convenience accessor: returns `Currency` value objects in the same
    /// order as `activeCodes`, silently skipping unknown codes (defensive
    /// against broken / stale UserDefaults written by an older build).
    var activeCurrencies: [Currency] {
        _activeCodes.compactMap { CurrencyCatalog.byCode($0) }
    }

    /// Adds a code at the end of the active list. No-op if already present.
    /// Unknown codes (not in `CurrencyCatalog`) are rejected silently —
    /// the caller is the Manage screen which only exposes valid codes.
    func add(_ code: String) {
        let upper = code.uppercased()
        guard CurrencyCatalog.isKnown(upper) else { return }
        guard !_activeCodes.contains(upper) else { return }
        activeCodes = _activeCodes + [upper]
    }

    /// Removes a code. No-op if missing. Refuses to remove the last
    /// remaining code — the picker must always have at least one option,
    /// and falling through to the "empty → defaults" path would
    /// surprise the user.
    func remove(_ code: String) {
        let upper = code.uppercased()
        guard _activeCodes.count > 1 else { return }
        activeCodes = _activeCodes.filter { $0 != upper }
    }

    /// Case-insensitive membership check.
    func contains(_ code: String) -> Bool {
        _activeCodes.contains(code.uppercased())
    }

    /// Replaces the order with the given list. Useful for drag-to-reorder
    /// in the Manage screen. Filters to currently-active codes only —
    /// passing in a code that wasn't already active is ignored.
    func reorder(_ newOrder: [String]) {
        let upper = newOrder.map { $0.uppercased() }
        let valid = upper.filter { _activeCodes.contains($0) }
        // Append any active codes the caller forgot, so we never lose
        // an entry on a partial reorder.
        let missing = _activeCodes.filter { !valid.contains($0) }
        activeCodes = valid + missing
    }

    /// Resets to the legacy 9-code default. Only used by tests right now;
    /// no UI surfaces it because users would want to keep their picks.
    func resetToDefaults() {
        defaults.removeObject(forKey: Self.storageKey)
        _activeCodes = Self.defaultCodes
    }

    // MARK: - Internals

    /// Reads + parses the persisted list. Returns the default 9 codes
    /// when the key is absent or the value is empty/garbage.
    private static func load(from defaults: UserDefaults) -> [String] {
        guard let raw = defaults.string(forKey: storageKey),
              !raw.isEmpty else {
            return defaultCodes
        }
        let parsed = normalize(raw.split(separator: ",").map(String.init))
        // If everything in storage is unrecognised (e.g. an old build
        // wrote a different format), fall back to defaults rather than
        // showing an empty inline list.
        return parsed.isEmpty ? defaultCodes : parsed
    }

    /// Uppercases, trims whitespace, drops empty/duplicate entries while
    /// preserving first-seen order.
    private static func normalize(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for code in codes {
            let upper = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !upper.isEmpty else { continue }
            guard !seen.contains(upper) else { continue }
            seen.insert(upper)
            out.append(upper)
        }
        return out
    }
}
