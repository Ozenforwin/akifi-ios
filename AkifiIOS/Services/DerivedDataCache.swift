import Foundation
import os

// MARK: - Memo keys

/// O(1) "is this still the very same array value?" check for memo keys.
///
/// The key keeps the array alive, so the storage address can only match if
/// the producer has neither reassigned nor mutated it since: mutating storage
/// that is also referenced here is forced to copy (copy-on-write) and lands
/// at a new address, and a freshly assigned array cannot reuse the address of
/// storage that is still alive. Comparing addresses is therefore exact,
/// without walking a single element.
///
/// This is what lets a view memoize "derived from `dataStore.transactions`"
/// without trusting that every write path remembered to bump a counter.
struct ArrayIdentity<Element>: Equatable {
    private let storage: [Element]

    init(_ array: [Element]) { storage = array }

    var count: Int { storage.count }

    static func == (lhs: ArrayIdentity, rhs: ArrayIdentity) -> Bool {
        guard lhs.storage.count == rhs.storage.count else { return false }
        if lhs.storage.isEmpty { return true }
        return lhs.address == rhs.address
    }

    private var address: UnsafeRawPointer? {
        storage.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
    }
}

/// Everything a number derived from the store's transactions depends on:
/// the rows themselves, the accounts (currency per account) and the FX
/// context. `txGenerationToken` is bumped by `rebuildCaches()` — which also
/// runs on every FX-rate / base-currency change — so it doubles as the FX
/// revision; no need to hash the rate table on every read.
///
/// Reading this property registers SwiftUI observation on `transactions` and
/// `accounts`, so a view whose memo hits is still invalidated when they change.
struct DerivationRevision: Equatable {
    let token: UInt64
    let transactions: ArrayIdentity<Transaction>
    let accounts: ArrayIdentity<Account>
}

extension DataStore {
    var derivationRevision: DerivationRevision {
        DerivationRevision(
            token: txGenerationToken,
            transactions: ArrayIdentity(transactions),
            accounts: ArrayIdentity(accounts)
        )
    }
}

/// Small memo: returns the cached value while the key is unchanged.
/// `capacity > 1` keeps a few recent keys (e.g. both sides of a toggle).
/// Not observable on purpose — writing it from `body` must not invalidate.
@MainActor
final class Memo<Key: Equatable, Value> {
    private var entries: [(key: Key, value: Value)] = []
    private let capacity: Int
    /// Number of times `compute` ran — exposed for tests.
    private(set) var computeCount = 0

    init(capacity: Int = 1) {
        self.capacity = max(1, capacity)
    }

    func value(for key: Key, _ compute: () -> Value) -> Value {
        if let index = entries.lastIndex(where: { $0.key == key }) {
            if index != entries.count - 1 {
                entries.append(entries.remove(at: index))
            }
            return entries[entries.count - 1].value
        }
        let value = compute()
        computeCount += 1
        entries.append((key, value))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        return value
    }

    func removeAll() { entries.removeAll() }
}

// MARK: - Day keys

/// Calendar-day keys in the user's time zone, always Gregorian — the same
/// "yyyy-MM-dd" shape as `Transaction.date`, so day filters become string
/// comparisons instead of one `DateFormatter.date(from:)` per row.
enum DayKey {
    /// Gregorian calendars per time-zone id, built once — these keys are
    /// computed from view bodies, which must not construct calendars.
    private static let calendars = OSAllocatedUnfairLock(initialState: [String: Calendar]())

    private static func gregorian(_ timeZone: TimeZone) -> Calendar {
        calendars.withLock { cache in
            if let cal = cache[timeZone.identifier] { return cal }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            cache[timeZone.identifier] = cal
            return cal
        }
    }

    /// "yyyy-MM-dd" of `date` in `timeZone`.
    static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        let c = gregorian(timeZone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "yyyy-MM" of `date` in `timeZone`.
    static func month(_ date: Date, timeZone: TimeZone = .current) -> String {
        let c = gregorian(timeZone).dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// The last `count` month keys ending with the month of `now`, oldest first.
    static func recentMonths(_ count: Int, now: Date = Date(), timeZone: TimeZone = .current) -> [String] {
        guard count > 0 else { return [] }
        let cal = gregorian(timeZone)
        return (0..<count).reversed().compactMap { offset in
            cal.date(byAdding: .month, value: -offset, to: now).map { month($0, timeZone: timeZone) }
        }
    }

    /// True for a well-formed "yyyy-MM-dd" day string.
    static func isDay(_ s: String) -> Bool { s.utf8.count == 10 }

    /// Exact string equivalent of "the row's local midnight is at or after
    /// `start`" — the filter every period widget used to evaluate with a
    /// date parse per row. Days after `start`'s day always pass; `start`'s
    /// own day passes only when `start` is itself a midnight.
    struct Threshold: Equatable {
        let key: String
        let inclusive: Bool

        init(since start: Date, timeZone: TimeZone = .current) {
            let cal = DayKey.gregorian(timeZone)
            key = DayKey.day(start, timeZone: timeZone)
            inclusive = cal.startOfDay(for: start) == start
        }

        func admits(_ day: String) -> Bool {
            guard DayKey.isDay(day) else { return false }
            return day > key || (inclusive && day == key)
        }
    }
}

// MARK: - Transaction index

/// O(N)-once lookups that transaction rows used to compute with a scan of
/// every transaction *per row*.
struct TransactionIndex {
    struct Leg: Equatable {
        let id: String
        let accountId: String?
    }

    /// Accounts holding at least one row written by someone other than the
    /// viewer. This is only the *legacy* "shared" signal — the fallback while
    /// `AccountMembershipStore` has no answer (offline before the first load).
    let accountsWithOtherAuthors: Set<String>
    /// `transfer_group_id` → legs in `transactions` order.
    let transferLegs: [String: [Leg]]
    /// Account → user ids that wrote at least one row on it.
    let authorsByAccount: [String: Set<String>]

    /// The first other leg of `tx`'s transfer group — what
    /// `transactions.first { $0.transferGroupId == g && $0.id != tx.id }` returned.
    func transferPartner(of tx: Transaction) -> Leg? {
        guard let group = tx.transferGroupId else { return nil }
        return transferLegs[group]?.first { $0.id != tx.id }
    }

    static func build(transactions: [Transaction], viewerId: String?) -> TransactionIndex {
        var others: Set<String> = []
        var legs: [String: [Leg]] = [:]
        var authors: [String: Set<String>] = [:]
        for tx in transactions {
            if let acc = tx.accountId {
                authors[acc, default: []].insert(tx.userId)
                if tx.userId != viewerId { others.insert(acc) }
            }
            if let group = tx.transferGroupId {
                legs[group, default: []].append(Leg(id: tx.id, accountId: tx.accountId))
            }
        }
        return TransactionIndex(accountsWithOtherAuthors: others, transferLegs: legs, authorsByAccount: authors)
    }
}

// MARK: - Transaction instants

/// The moment a transaction happened, from `Transaction.rawDateTime`.
///
/// `Transaction.date` is only the UTC calendar day; comparing its midnight
/// with an instant (a settlement's `settled_at`) made an evening expense look
/// older than a settlement recorded that morning (D11).
enum TransactionInstant {
    private static var wallClock: DateFormatter { AppDateFormatters.utcDateTime }

    private static var dayOnly: DateFormatter { AppDateFormatters.utcDate }

    /// Parses PostgREST timestamps — `2026-11-16T14:38:22+00:00`, with or
    /// without fractional seconds (any precision), `Z`, `±HH`, `±HHMM` or
    /// `±HH:MM`, `T` or space separator. A value without an offset (an
    /// offline placeholder's local wall time) is read as UTC — which is how
    /// the server stores it. A bare day is its UTC midnight.
    static func parse(_ raw: String) -> Date? {
        let s = Array(raw.utf8)
        if s.count == 10 {
            return dayOnly.date(from: raw)
        }
        guard s.count >= 19 else { return nil }
        var head = String(decoding: s[0..<19], as: UTF8.self)
        if s[10] == UInt8(ascii: " ") {
            head = String(head.prefix(10)) + "T" + String(head.dropFirst(11))
        }
        guard var date = wallClock.date(from: head) else { return nil }

        var i = 19
        if i < s.count, s[i] == UInt8(ascii: ".") {
            i += 1
            var fraction = 0.0
            var scale = 0.1
            while i < s.count, let d = digit(s[i]) {
                fraction += Double(d) * scale
                scale /= 10
                i += 1
            }
            date += fraction
        }
        guard i < s.count else { return date }
        switch s[i] {
        case UInt8(ascii: "Z"), UInt8(ascii: "z"):
            return date
        case UInt8(ascii: "+"), UInt8(ascii: "-"):
            let sign: Double = s[i] == UInt8(ascii: "+") ? 1 : -1
            let digits = s[(i + 1)...].compactMap(digit)
            guard digits.count == 2 || digits.count == 4 else { return nil }
            let hours = digits[0] * 10 + digits[1]
            let minutes = digits.count == 4 ? digits[2] * 10 + digits[3] : 0
            date -= sign * Double(hours * 3600 + minutes * 60)
            return date
        default:
            return nil
        }
    }

    private static func digit(_ byte: UInt8) -> Int? {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") ? Int(byte - UInt8(ascii: "0")) : nil
    }
}

// MARK: - Per-store cache

/// Memoized derivations shared by many views of one `DataStore` (rows,
/// Home cards). Lives beside the store rather than inside it so the store's
/// owners don't have to know about view-level lookups; every entry is keyed
/// by `DerivationRevision`, never by a timer or a "small enough" guess.
@MainActor
final class DerivedDataCache {
    private struct IndexKey: Equatable {
        let revision: DerivationRevision
        let viewerId: String?
    }

    private struct RecentKey: Equatable {
        let revision: DerivationRevision
        let accountId: String?
        let limit: Int
    }

    private let indexMemo = Memo<IndexKey, TransactionIndex>()
    private let recentMemo = Memo<RecentKey, [Transaction]>(capacity: 4)

    var indexComputeCount: Int { indexMemo.computeCount }

    func transactionIndex(for store: DataStore) -> TransactionIndex {
        let key = IndexKey(revision: store.derivationRevision, viewerId: store.profile?.id)
        return indexMemo.value(for: key) {
            TransactionIndex.build(transactions: store.transactions, viewerId: key.viewerId)
        }
    }

    /// Latest `limit` rows (optionally on one account), one row per
    /// `transfer_group_id` — Home's "recent transactions" list.
    func recentTransactions(for store: DataStore, accountId: String?, limit: Int = 10) -> [Transaction] {
        let key = RecentKey(revision: store.derivationRevision, accountId: accountId, limit: limit)
        return recentMemo.value(for: key) {
            Self.recent(store.transactions, accountId: accountId, limit: limit)
        }
    }

    nonisolated static func recent(_ transactions: [Transaction], accountId: String?, limit: Int) -> [Transaction] {
        var out: [Transaction] = []
        out.reserveCapacity(limit)
        var seenGroups: Set<String> = []
        for tx in transactions {
            if let accountId, tx.accountId != accountId { continue }
            if let groupId = tx.transferGroupId {
                if seenGroups.contains(groupId) { continue }
                seenGroups.insert(groupId)
            }
            out.append(tx)
            if out.count == limit { break }
        }
        return out
    }
}

// MARK: - Companion registry

/// One `DerivedDataCache` + `AccountMembershipStore` per `DataStore`
/// instance (the app has one; tests and benchmarks build many). Entries
/// whose store is gone are pruned on the next lookup.
@MainActor
private enum DataStoreCompanions {
    @MainActor
    final class Entry {
        weak var owner: DataStore?
        let derived = DerivedDataCache()
        let membership = AccountMembershipStore()
        init(owner: DataStore) { self.owner = owner }
    }

    static var entries: [ObjectIdentifier: Entry] = [:]

    static func entry(for store: DataStore) -> Entry {
        let id = ObjectIdentifier(store)
        if let entry = entries[id], entry.owner === store {
            return entry
        }
        entries = entries.filter { $0.value.owner != nil }
        let entry = Entry(owner: store)
        entries[id] = entry
        return entry
    }
}

extension DataStore {
    /// Memoized view-level lookups for this store (see `DerivedDataCache`).
    var derivedCache: DerivedDataCache { DataStoreCompanions.entry(for: self).derived }

    /// Who is a member of which account (see `AccountMembershipStore`).
    var accountMembership: AccountMembershipStore { DataStoreCompanions.entry(for: self).membership }
}
