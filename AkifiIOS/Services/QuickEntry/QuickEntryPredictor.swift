import Foundation

/// A ranked category for a new entry.
struct QuickEntryCategorySuggestion: Equatable, Sendable, Identifiable {
    enum Reason: String, Equatable, Sendable {
        /// The same description / merchant was filed under it before —
        /// the most recent such row comes first.
        case sameText
        /// A word of the phrase is the category's name.
        case categoryName
        /// A similar description was filed under it.
        case similarText
        /// Used often, recently, at this time of day / day of week.
        case frequent
    }

    let categoryId: String
    /// 0…1. ≥ `QuickEntryPredictor.autoApplyThreshold` is applied without
    /// asking; below it the UI offers it as a chip.
    let confidence: Double
    let reason: Reason

    var id: String { categoryId }
}

/// One-tap repeat of a recent entry («кофе 300 ₽ · Кафе · Тинькофф»).
struct QuickEntryRepeatItem: Equatable, Sendable, Identifiable {
    /// Stable identity of the combination (description, category, account,
    /// amount, currency).
    let id: String
    let sourceTransactionId: String
    let type: TransactionType
    let description: String
    let categoryId: String?
    let accountId: String
    /// What the user entered: the foreign amount when the row was typed in
    /// another currency, otherwise the account amount. Main units.
    let amount: Decimal
    /// Entry currency of `amount` (ISO, uppercase).
    let currencyCode: String
    /// ADR-001: the stored amount, kopecks in `accountCurrency`.
    let amountNative: Int64
    let accountCurrency: String
    let lastUsed: Date?
    /// How many history rows share this combination.
    let useCount: Int

    /// Overrides that recreate this entry in the engine — the date is now,
    /// a foreign amount is converted again at today's rate on save.
    var overrides: QuickEntryOverrides {
        QuickEntryOverrides(
            type: type,
            amount: amount,
            currencyCode: currencyCode,
            accountId: accountId,
            category: categoryId.map { .category($0) } ?? .none,
            description: description
        )
    }
}

/// Category prediction and «repeat recent» from the user's own history.
/// Pure: same context, text and clock → same answer.
///
/// Ranking, per type (expense and income never mix):
/// 1. same text — the category of the user's most recent row with this
///    exact description or merchant (a partner's row on a shared account
///    when the user has none);
/// 2. category name — a word of the phrase names a category. It goes
///    first when only a partner's rows carry the same text: «кофе» filed
///    under «Продукты» by a partner must not beat the user's own «Кофе»
///    category (device feedback 2026-11-28). The user's own history still
///    wins over a name — that is how a correction is learned;
/// 3. similar text — fuzzy word overlap with past descriptions;
/// 4. frequency — recency-weighted use, boosted at a similar time of day
///    and day of week.
/// Hidden categories are never returned; partner duplicates on shared
/// accounts count for their display twin (`QuickEntryContext`).
enum QuickEntryPredictor {

    /// Suggestions at or above this are applied automatically.
    static let autoApplyThreshold = 0.55
    /// Half-life of a history row's weight.
    static let recencyHalfLifeDays = 45.0

    static func rankCategories(
        text: String,
        type: TransactionType,
        accountId: String? = nil,
        entryDate: Date,
        nameHints: [QuickEntryParse.CategoryHint] = [],
        context: QuickEntryContext,
        now: Date = Date(),
        limit: Int = 5
    ) -> [QuickEntryCategorySuggestion] {
        guard type != .transfer, limit > 0 else { return [] }
        let candidates = context.displayCategories(for: type)
        let valid = Set(candidates.map(\.id))
        guard !valid.isEmpty else { return [] }

        let items = context.history.filter { $0.type == type }
        let calendar = context.calendar
        let today = calendar.startOfDay(for: now)
        func weight(_ item: QuickEntryHistoryItem) -> Double {
            var w = 1.0
            if let day = item.day {
                let age = max(0, calendar.dateComponents([.day], from: day, to: today).day ?? 0)
                w = pow(0.5, Double(age) / recencyHalfLifeDays)
            } else {
                w = 0.1
            }
            if !item.isOwn { w *= 0.5 }
            if let accountId, item.accountId == accountId { w *= 1.25 }
            return w
        }

        var result: [QuickEntryCategorySuggestion] = []
        var taken: Set<String> = []
        func add(_ id: String, _ confidence: Double, _ reason: QuickEntryCategorySuggestion.Reason) {
            guard valid.contains(id), !taken.contains(id) else { return }
            taken.insert(id)
            result.append(QuickEntryCategorySuggestion(categoryId: id, confidence: min(1, max(0, confidence)), reason: reason))
        }

        let identity = QuickEntryText.identityKey(text)
        let keys = QuickEntryText.matchKeys(text)

        // 2 (computed first). Categories the phrase names, strongest first.
        var named: [(id: String, confidence: Double)] = []
        for hint in nameHints where hint.type.rawValue == type.rawValue {
            guard let id = context.displayCategoryIdById[hint.categoryId], valid.contains(id),
                  !named.contains(where: { $0.id == id }) else { continue }
            named.append((id, 0.6 + 0.25 * hint.confidence))
        }

        // 1. Same text: the user's most recent row, else a partner's.
        var sameText: [(id: String, confidence: Double)] = []
        var sameTextIsOwn = false
        if !identity.isEmpty {
            let same = items.filter {
                ($0.identity == identity || $0.merchantIdentity == identity) && $0.categoryId.map(valid.contains) == true
            }
            let latestOwn = same.first(where: \.isOwn)
            sameTextIsOwn = latestOwn != nil
            if let latest = latestOwn ?? same.first, let latestCategory = latest.categoryId {
                var byCategory: [String: Double] = [:]
                for item in same { byCategory[item.categoryId!, default: 0] += weight(item) }
                let total = byCategory.values.reduce(0, +)
                let share = total > 0 ? (byCategory[latestCategory] ?? 0) / total : 1
                let top = 0.7 + 0.25 * share
                sameText.append((latestCategory, top))
                for (id, w) in byCategory.sorted(by: { $0.value > $1.value }) where id != latestCategory {
                    sameText.append((id, min(top - 0.01, 0.35 + 0.3 * (total > 0 ? w / total : 0))))
                }
            }
        }

        // A named category goes first unless the user's own rows with this
        // text say otherwise (a partner's filing never overrules the name).
        let nameFirst: Bool = {
            guard let topNamed = named.first else { return false }
            guard let topSame = sameText.first else { return true }
            return topSame.id != topNamed.id && !sameTextIsOwn
        }()
        if nameFirst, let topNamed = named.first {
            for item in named { add(item.id, item.confidence, .categoryName) }
            for item in sameText { add(item.id, min(item.confidence, topNamed.confidence - 0.01), .sameText) }
        } else {
            for item in sameText { add(item.id, item.confidence, .sameText) }
            for item in named { add(item.id, item.confidence, .categoryName) }
        }

        // 3. Similar text.
        if !keys.isEmpty {
            var best: [String: Double] = [:]
            var mass: [String: Double] = [:]
            for item in items {
                guard let cat = item.categoryId, valid.contains(cat), !item.keys.isEmpty else { continue }
                let sim = QuickEntryText.overlap(keys, item.keys)
                guard sim >= 0.3 else { continue }
                best[cat] = max(best[cat] ?? 0, sim)
                mass[cat, default: 0] += sim * weight(item)
            }
            let totalMass = mass.values.reduce(0, +)
            let ranked = best.keys.sorted { a, b in
                let sa = (best[a] ?? 0) * (0.7 + 0.3 * (mass[a] ?? 0) / max(totalMass, 0.0001))
                let sb = (best[b] ?? 0) * (0.7 + 0.3 * (mass[b] ?? 0) / max(totalMass, 0.0001))
                return sa != sb ? sa > sb : a < b
            }
            for id in ranked {
                let share = (mass[id] ?? 0) / max(totalMass, 0.0001)
                add(id, 0.3 + 0.4 * (best[id] ?? 0) * (0.7 + 0.3 * share), .similarText)
            }
        }

        // 4. Frequency, weighted by recency and the moment of the entry.
        let entryHour = calendar.component(.hour, from: entryDate)
        let entryWeekday = calendar.component(.weekday, from: entryDate)
        var frequency: [String: Double] = [:]
        for item in items {
            guard let cat = item.categoryId, valid.contains(cat) else { continue }
            var w = weight(item)
            if let hour = item.hour {
                let diff = abs(hour - entryHour)
                let circular = min(diff, 24 - diff)
                w *= circular <= 1 ? 1.6 : (circular <= 3 ? 1.25 : 1)
            }
            if let day = item.day {
                let weekday = calendar.component(.weekday, from: day)
                if weekday == entryWeekday {
                    w *= 1.3
                } else if isWeekend(weekday) == isWeekend(entryWeekday) {
                    w *= 1.1
                }
            }
            frequency[cat, default: 0] += w
        }
        let totalFrequency = frequency.values.reduce(0, +)
        for (id, w) in frequency.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) {
            add(id, 0.1 + 0.35 * (totalFrequency > 0 ? w / totalFrequency : 0), .frequent)
        }

        return Array(result.prefix(limit))
    }

    /// The type the same text was always entered with, if it was ever
    /// entered and always the same way («зарплата» → income).
    static func historyType(for text: String, context: QuickEntryContext) -> TransactionType? {
        let identity = QuickEntryText.identityKey(text)
        guard !identity.isEmpty else { return nil }
        let types = Set(context.history.filter {
            $0.identity == identity || $0.merchantIdentity == identity
        }.map(\.type))
        return types.count == 1 ? types.first : nil
    }

    private static func isWeekend(_ weekday: Int) -> Bool {
        weekday == 1 || weekday == 7
    }

    // MARK: - Repeat recent

    /// The most recent distinct (description, category, account, amount,
    /// currency) combinations of the signed-in user, newest first.
    /// Rows on deleted accounts and rows with neither a description nor a
    /// category are skipped; a hidden category is dropped (nil).
    static func repeatCandidates(
        context: QuickEntryContext,
        type: TransactionType? = nil,
        limit: Int = 6
    ) -> [QuickEntryRepeatItem] {
        guard limit > 0 else { return [] }
        var order: [String] = []
        var first: [String: QuickEntryRepeatItem] = [:]
        var counts: [String: Int] = [:]

        for item in context.history where item.isOwn {
            if let type, item.type != type { continue }
            guard let accountId = item.accountId, let account = context.account(accountId) else { continue }
            guard !item.text.isEmpty || item.categoryId != nil else { continue }
            let accountCurrency = account.currency.uppercased()
            let amount: Decimal
            let currency: String
            if let foreignAmount = item.foreignAmount, let foreignCurrency = item.foreignCurrency, foreignAmount > 0 {
                amount = foreignAmount
                currency = foreignCurrency.uppercased()
            } else {
                amount = abs(item.amountNative).displayAmount
                currency = accountCurrency
            }
            guard amount > 0 else { continue }
            let key = [
                item.type.rawValue, item.identity, item.categoryId ?? "-", accountId,
                "\(amount)", currency
            ].joined(separator: "|")
            counts[key, default: 0] += 1
            guard first[key] == nil else { continue }
            order.append(key)
            first[key] = QuickEntryRepeatItem(
                id: key,
                sourceTransactionId: item.transactionId,
                type: item.type,
                description: item.text,
                categoryId: item.categoryId,
                accountId: accountId,
                amount: amount,
                currencyCode: currency,
                amountNative: abs(item.amountNative),
                accountCurrency: accountCurrency,
                lastUsed: item.day,
                useCount: 0
            )
        }
        return order.prefix(limit).compactMap { key in
            guard let item = first[key] else { return nil }
            return QuickEntryRepeatItem(
                id: item.id,
                sourceTransactionId: item.sourceTransactionId,
                type: item.type,
                description: item.description,
                categoryId: item.categoryId,
                accountId: item.accountId,
                amount: item.amount,
                currencyCode: item.currencyCode,
                amountNative: item.amountNative,
                accountCurrency: item.accountCurrency,
                lastUsed: item.lastUsed,
                useCount: counts[key] ?? 1
            )
        }
    }
}
