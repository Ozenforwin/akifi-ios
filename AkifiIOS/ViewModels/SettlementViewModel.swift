import Foundation
import Observation
@preconcurrency import Supabase

/// Periods supported by the settlement card picker.
enum SettlementPeriod: Hashable, Sendable {
    case thisMonth
    case lastMonth
    case quarter
    case ytd
    case custom(DateInterval)

    var localizedTitle: String {
        switch self {
        case .thisMonth:  return String(localized: "settlement.period.thisMonth")
        case .lastMonth:  return String(localized: "settlement.period.lastMonth")
        case .quarter:    return String(localized: "settlement.period.quarter")
        case .ytd:        return String(localized: "settlement.period.ytd")
        case .custom:     return String(localized: "settlement.period.custom")
        }
    }

    /// Interval in the frame transaction dates live in (M6): rows carry
    /// the author's LOCAL wall clock under a UTC label, so "this month" is
    /// the user's local month written the same way — month boundaries of
    /// the UTC calendar around the wall-clock "now". Reading the real
    /// instant in UTC showed November's rows until 03:00 on 1 December in
    /// Moscow.
    func transactionInterval(now: Date = Date(), timeZone: TimeZone = .current) -> DateInterval {
        dateInterval(reference: TransactionInstant.wallClock(of: now, in: timeZone), calendarTimeZone: AppDateFormatters.utcTimeZone)
    }

    /// Interval of real instants (`settled_at`), month boundaries in the
    /// user's zone (M6): a settlement at 01:30 on 1 December in Moscow is
    /// December's, not November's.
    func instantInterval(now: Date = Date(), timeZone: TimeZone = .current) -> DateInterval {
        dateInterval(reference: now, calendarTimeZone: timeZone)
    }

    func dateInterval(reference: Date = Date(), calendarTimeZone: TimeZone = AppDateFormatters.utcTimeZone) -> DateInterval {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = calendarTimeZone
        let now = reference
        switch self {
        case .thisMonth:
            return cal.dateInterval(of: .month, for: now) ?? DateInterval(start: now, duration: 0)
        case .lastMonth:
            let lastMonthDate = cal.date(byAdding: .month, value: -1, to: now) ?? now
            return cal.dateInterval(of: .month, for: lastMonthDate) ?? DateInterval(start: now, duration: 0)
        case .quarter:
            return cal.dateInterval(of: .quarter, for: now) ?? DateInterval(start: now, duration: 0)
        case .ytd:
            let year = cal.component(.year, from: now)
            let start = cal.date(from: DateComponents(year: year, month: 1, day: 1)) ?? now
            return DateInterval(start: start, end: now)
        case .custom(let interval):
            return interval
        }
    }
}

/// Observable facade over `SettlementCalculator`. A `SharedAccountDetailView`
/// or `AccountSettlementCardView` creates one instance per shared account
/// and calls `load(sharedAccountId:)` on appear / period-change.
///
/// **Balance scope is cumulative.** The "who owes whom" card always reflects
/// the all-time net, not the selected period. Reason: a period-scoped balance
/// produced phantom reverse-direction debts after a settlement closed at a
/// wider scope (e.g. settle in YTD, then the month view re-applied the
/// YTD-scoped settlement to the month's standalone delta and inverted it).
/// `selectedPeriod` now only filters the closed-history list and the
/// transaction list below the card.
@MainActor
@Observable
final class SettlementViewModel {
    var selectedPeriod: SettlementPeriod = .thisMonth

    var balances: [SettlementCalculator.MemberBalance] = []
    var suggestions: [SettlementCalculator.SettlementSuggestion] = []
    var pastSettlements: [Settlement] = []
    /// Per-member, per-transaction settlement marks for this shared account.
    /// Refreshed alongside `pastSettlements` on every `load`. The UI groups
    /// these by `transaction_id` to render the row toggle / per-member sheet.
    var transactionMemberSettlements: [TransactionMemberSettlement] = []
    /// Main expense id → payer, as resolved by the server. Empty when the
    /// server call failed (offline) — callers fall back to local attribution.
    var serverPayers: [String: String] = [:]
    /// `true` when `balances` came from `get_account_settlement` (identical
    /// for every member); `false` when we fell back to the local calculator.
    var isServerComputed = false

    /// How far the card's numbers can be trusted (M7).
    enum Reliability: Equatable, Sendable {
        /// Server balances, settlements and per-row marks all loaded.
        case confirmed
        /// Something is missing (offline): numbers are an estimate — shown
        /// as «приблизительно, нет связи», no suggestions, no recording.
        case approximate
        /// Neither the server nor the settlement history answered: a local
        /// computation without past settlements would re-suggest debts that
        /// are already closed, so no balances at all.
        case unavailable
    }

    private(set) var reliability: Reliability = .confirmed

    /// Recording (or undoing) a settlement / per-row mark is only offered
    /// on confirmed numbers. Offline the local fallback ran without the
    /// settlement history and offered «A → B 5 858,92 ₽» again; tapping it
    /// once the network was back wrote a second settlement and flipped the
    /// debt (M7).
    var canRecordSettlements: Bool { reliability == .confirmed }

    nonisolated static func reliability(serverOK: Bool, settlementsLoaded: Bool, marksLoaded: Bool) -> Reliability {
        if serverOK && settlementsLoaded && marksLoaded { return .confirmed }
        if !serverOK && !settlementsLoaded { return .unavailable }
        return .approximate
    }

    /// Settle suggestions are built only from confirmed balances (M7).
    nonisolated static func suggestions(
        from balances: [SettlementCalculator.MemberBalance],
        reliability: Reliability
    ) -> [SettlementCalculator.SettlementSuggestion] {
        guard reliability == .confirmed else { return [] }
        return SettlementCalculator.settlements(from: balances)
    }
    var isLoading = false
    var errorMessage: String?

    private let settlementRepo = SettlementRepository()
    private let txMemberRepo = TransactionMemberSettlementRepository()
    private let supabase = SupabaseManager.shared.client

    /// Wide-open interval used for cumulative balance computation. Pass to
    /// `SettlementCalculator.compute` so every in-account transaction and
    /// every recorded settlement contributes to the running net.
    private static let cumulativeInterval = DateInterval(
        start: .distantPast,
        end: .distantFuture
    )

    /// Recomputes balances + suggestions for `sharedAccountId` using the
    /// transactions & accounts currently in `dataStore`. Also fetches past
    /// settlements for display. Pass `currencyManager` to enable
    /// FX-correct settlement math for cross-currency auto-transfer legs;
    /// omitting it (or passing one with empty `rates`) falls back to
    /// face-value math (legacy behavior).
    func load(
        sharedAccountId: String,
        dataStore: DataStore,
        currencyManager: CurrencyManager? = nil
    ) async {
        isLoading = true
        errorMessage = nil

        // All four reads are independent — run them concurrently so the card
        // costs one round-trip, not four sequential ones.
        let client = supabase
        let settlementRepo = settlementRepo
        let txMemberRepo = txMemberRepo
        // Members come from the app-wide membership snapshot when it's loaded
        // (Home and the account screen share it — P7); only a cold screen
        // pays for its own read.
        let cachedMembers = dataStore.accountMembership.members(of: sharedAccountId, viewerId: dataStore.profile?.id)
        async let membersFetch: [AccountMember] = Self.members(cached: cachedMembers, client: client, accountId: sharedAccountId)
        async let settlementsFetch = settlementRepo.fetchForAccount(sharedAccountId)
        async let marksFetch = txMemberRepo.fetchForAccount(sharedAccountId)
        async let serverFetch = settlementRepo.fetchServerSettlement(sharedAccountId)

        // Pull canonical member list from `account_members` (falls back to
        // transaction-authors if the network call fails — keeps legacy
        // behavior for accounts without the join). Read split_weight at
        // the same time so the settlement math can honor per-member shares.
        var members: [AccountMember] = []
        do {
            members = try await membersFetch
        } catch {
            // Non-fatal — fall back to deriving from transactions below.
            AppLogger.data.debug("settlement members load: \(error.localizedDescription)")
        }

        let memberUserIds: [String]
        let memberWeights: [String: Decimal]
        if !members.isEmpty {
            memberUserIds = members.map(\.userId)
            memberWeights = Dictionary(uniqueKeysWithValues: members.map { ($0.userId, $0.splitWeight) })
        } else {
            memberUserIds = Array(
                Set(dataStore.transactions
                    .filter { $0.accountId == sharedAccountId }
                    .map(\.userId))
            )
            memberWeights = [:]
        }

        // Build personalAccountsByUser from the accounts visible to us.
        // Every account we can see that is NOT the shared one is considered
        // "personal" for attribution purposes.
        var personalMap: [String: Set<String>] = [:]
        for acc in dataStore.accounts where acc.id != sharedAccountId {
            personalMap[acc.userId, default: []].insert(acc.id)
        }

        // Fetch past settlements BEFORE compute so closed debts are applied
        // to balances and don't show up again as live suggestions. Also
        // fetch per-member, per-txn marks — they nudge the contributions
        // map the same way an aggregate settlement does, but at txn-row
        // granularity (used by the swipe / sheet UX).
        var settlementsLoaded = false
        var marksLoaded = false
        do {
            pastSettlements = try await settlementsFetch
            settlementsLoaded = true
        } catch {
            // Offline is reported through `reliability`, not as a red error.
            AppLogger.data.debug("settlements load: \(error.localizedDescription)")
        }
        do {
            transactionMemberSettlements = try await marksFetch
            marksLoaded = true
        } catch {
            // Non-fatal — feature is additive; falling through with the
            // previous list (or empty) keeps the rest of the card working.
            AppLogger.data.debug("txn-member settlements load: \(error.localizedDescription)")
        }

        // Shared account's native currency drives the FX base. `Account.currency`
        // returns uppercase ISO 4217; `CurrencyManager.rates` also keyed by
        // uppercase so they align. When the shared account row is missing
        // (rare but possible during reload) we leave baseCurrency = nil and
        // the calculator falls back to face-value math.
        let sharedAccount = dataStore.accounts.first { $0.id == sharedAccountId }
        let fxRates = currencyManager?.rates ?? [:]
        let baseCurrency = sharedAccount?.currency

        // Always cumulative: every transaction on the shared account and every
        // recorded settlement counts toward the running net. The period selector
        // filters the history & transaction lists, not the balance card.
        //
        // The local computation is the offline fallback and a cross-check;
        // the server's answer (identical for every member) is the source of
        // truth whenever it is available.
        let local = SettlementCalculator.compute(
            sharedAccountId: sharedAccountId,
            transactions: dataStore.transactions,
            memberUserIds: memberUserIds,
            personalAccountsByUser: personalMap,
            period: Self.cumulativeInterval,
            pastSettlements: pastSettlements,
            transactionMemberSettlements: transactionMemberSettlements,
            memberWeights: memberWeights,
            fxRates: fxRates,
            baseCurrency: baseCurrency
        )

        var serverOK = false
        do {
            let server = try await serverFetch
            balances = server.memberBalances
            serverPayers = server.payers
            isServerComputed = true
            serverOK = true
            // Compare only when the local side had everything the server
            // had — otherwise a "mismatch" is just missing offline data.
            if settlementsLoaded, marksLoaded,
               let diff = Self.integrityMismatch(server: balances, local: local),
               Self.shouldReportMismatch(accountId: sharedAccountId) {
                // The phone's own view disagrees with the server — the class
                // of bug that showed different debts to the two members of
                // «Семейный». Server wins; we want to hear about it.
                AppLogger.data.error(
                    "settlement mismatch: server vs local differ by \(diff) kopecks (members: \(self.balances.count, privacy: .public))"
                )
                AnalyticsService.logEvent("settlement_integrity_mismatch", params: [
                    "max_diff_kopecks": diff,
                    "members": balances.count,
                ])
            }
        } catch {
            // Offline / RPC unavailable → local fallback.
            AppLogger.data.error("get_account_settlement failed, using local fallback: \(error.localizedDescription)")
            balances = local
            serverPayers = [:]
            isServerComputed = false
        }
        reliability = Self.reliability(
            serverOK: serverOK, settlementsLoaded: settlementsLoaded, marksLoaded: marksLoaded
        )
        if reliability == .unavailable { balances = [] }
        suggestions = Self.suggestions(from: balances, reliability: reliability)

        isLoading = false
    }

    // MARK: - Mismatch event dedupe (M10)

    /// One `settlement_integrity_mismatch` per account per local day — it
    /// used to fire on every visit of the screen.
    nonisolated static func mismatchDedupeKey(accountId: String, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        "settlement.mismatch.reported.\(accountId).\(AppDateFormatters.localDate(in: timeZone).string(from: now))"
    }

    nonisolated static func shouldReportMismatch(
        accountId: String,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> Bool {
        let key = mismatchDedupeKey(accountId: accountId, now: now)
        guard !defaults.bool(forKey: key) else { return false }
        defaults.set(true, forKey: key)
        return true
    }

    nonisolated private static func members(
        cached: [AccountMember]?,
        client: SupabaseClient,
        accountId: String
    ) async throws -> [AccountMember] {
        if let cached, !cached.isEmpty { return cached }
        return try await SupabasePaging.all("account_members") { count in
            client
                .from("account_members")
                .select(count: count)
                .eq("account_id", value: accountId)
        }
    }

    /// Largest per-member delta disagreement between the server and the local
    /// computation, or `nil` when they agree. Up to one kopeck per member is
    /// tolerated: the rounding residual of the fair share lands on a different
    /// member when the two sides order members differently.
    nonisolated static func integrityMismatch(
        server: [SettlementCalculator.MemberBalance],
        local: [SettlementCalculator.MemberBalance]
    ) -> Int64? {
        let localById = Dictionary(local.map { ($0.userId.lowercased(), $0.delta) }, uniquingKeysWith: { a, _ in a })
        let serverById = Dictionary(server.map { ($0.userId.lowercased(), $0.delta) }, uniquingKeysWith: { a, _ in a })
        let ids = Set(localById.keys).union(serverById.keys)
        let maxDiff = ids.map { abs((serverById[$0] ?? 0) - (localById[$0] ?? 0)) }.max() ?? 0
        let tolerance = Int64(max(serverById.count, localById.count))
        return maxDiff > tolerance ? maxDiff : nil
    }

    /// Past settlements *recorded* during the currently selected period —
    /// used by the "История расчётов" section of the card.
    ///
    /// Filter is keyed off `settledAt` / `createdAt` (the moment the
    /// settlement was made), NOT `period_end`. Reason: with cumulative
    /// balances we no longer scope a settlement to a period — recording
    /// `period_end = today` for a YTD settle would otherwise duplicate the
    /// row across every period whose interval contains "today" (month,
    /// quarter, YTD all show it). Filtering by *when the settlement
    /// happened* keeps each row in exactly one period view.
    var pastSettlementsForCurrentPeriod: [Settlement] {
        Self.settlements(pastSettlements, in: selectedPeriod.instantInterval())
    }

    /// `settled_at` is a real instant: bucket it by the user's local month
    /// (`SettlementPeriod.instantInterval`), M6.
    nonisolated static func settlements(_ all: [Settlement], in interval: DateInterval) -> [Settlement] {
        all.filter { s in
            let raw = s.settledAt ?? s.createdAt
            guard let raw, let parsed = AppDateFormatters.parseTimestamp(raw) else { return false }
            return interval.contains(parsed)
        }
    }

    /// "Settlement watermark" — the timestamp of the most recent cumulative
    /// settle (`Отметить выполненным`). Because balances are cumulative, a
    /// settle closes the ENTIRE outstanding net debt as of the moment it was
    /// recorded, so every auto-transfer transaction dated on or before this
    /// line is already folded into a closed debt. The transactions list uses
    /// it to paint pre-watermark rows as "settled" instead of re-flagging
    /// them "Ожидает расчёта" the moment a new expense reopens the net debt.
    ///
    /// `nil` until the first settle exists. Caveat: for >2-member accounts a
    /// settle can be partial (the user closes only some of several
    /// suggestions); we still treat the whole pre-watermark span as settled.
    /// For a 2-member account a single settle always zeroes the net debt, so
    /// the approximation is exact there.
    var settlementWatermark: Date? {
        Self.watermark(from: pastSettlements)
    }

    /// Pure, side-effect-free watermark computation — the latest
    /// `settledAt` (falling back to `createdAt`) across the given
    /// settlements. Factored out so it's unit-testable without standing up
    /// the view model (which pulls in Supabase).
    nonisolated static func watermark(from settlements: [Settlement]) -> Date? {
        settlements.compactMap { s -> Date? in
            guard let raw = s.settledAt ?? s.createdAt else { return nil }
            return AppDateFormatters.parseTimestamp(raw)
        }.max()
    }

    /// Records a settlement in the `settlements` table and recomputes
    /// balances/suggestions so the closed debt collapses visually.
    func markSettled(
        suggestion: SettlementCalculator.SettlementSuggestion,
        sharedAccountId: String,
        currency: String,
        dataStore: DataStore,
        currencyManager: CurrencyManager? = nil
    ) async {
        guard canRecordSettlements else {
            errorMessage = String(localized: "settlement.offline.approximate")
            return
        }
        do {
            let user = try await SupabaseManager.shared.currentUserId()
            // Informational period, in the transactions' wall-clock days.
            let fmt = AppDateFormatters.utcDate
            let interval = selectedPeriod.transactionInterval()

            let input = CreateSettlementInput(
                shared_account_id: sharedAccountId,
                from_user_id: suggestion.fromUserId,
                to_user_id: suggestion.toUserId,
                amount: suggestion.amount,
                currency: currency,
                period_start: fmt.string(from: interval.start),
                period_end: fmt.string(from: interval.end),
                settled_by: user,
                linked_transfer_group_id: nil,
                note: nil
            )
            _ = try await settlementRepo.create(input)

            // Full reload — refetch past settlements + recompute balances &
            // suggestions with the new closure applied.
            await load(
                sharedAccountId: sharedAccountId,
                dataStore: dataStore,
                currencyManager: currencyManager
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Undoes a past settlement (deletes the DB row) and reopens the debt
    /// for the current period. Only the creator can delete per RLS.
    func cancelSettlement(
        _ settlement: Settlement,
        sharedAccountId: String,
        dataStore: DataStore,
        currencyManager: CurrencyManager? = nil
    ) async {
        do {
            try await settlementRepo.delete(id: settlement.id)
            await load(
                sharedAccountId: sharedAccountId,
                dataStore: dataStore,
                currencyManager: currencyManager
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Indexed view of `transactionMemberSettlements` for fast UI lookups —
    /// `marks[txnId]` gives the set of `settled_for_user_id`s closed for
    /// that txn. Empty set when the txn is fully open.
    var memberSettlementsByTxn: [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for s in transactionMemberSettlements {
            out[s.transactionId, default: []].insert(s.settledForUserId)
        }
        return out
    }

    /// Records a per-member settlement mark for a single `(txn, member)`
    /// pair and reloads. Inserting a duplicate (same txn+member) hits the
    /// UNIQUE constraint and is treated as a no-op via the catch.
    func markTxnShareSettled(
        transactionId: String,
        sharedAccountId: String,
        settledForUserId: String,
        note: String? = nil,
        dataStore: DataStore,
        currencyManager: CurrencyManager? = nil
    ) async {
        guard canRecordSettlements else {
            errorMessage = String(localized: "settlement.offline.approximate")
            return
        }
        do {
            let me = try await SupabaseManager.shared.currentUserId()
            let input = CreateTransactionMemberSettlementInput(
                transaction_id: transactionId,
                shared_account_id: sharedAccountId,
                settled_for_user_id: settledForUserId,
                settled_by_user_id: me,
                note: note
            )
            _ = try await txMemberRepo.create(input)
            await load(
                sharedAccountId: sharedAccountId,
                dataStore: dataStore,
                currencyManager: currencyManager
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Removes a per-member settlement mark and reloads. RLS lets only the
    /// original marker delete; non-marker callers see a silent no-op.
    func unmarkTxnShareSettled(
        transactionId: String,
        sharedAccountId: String,
        settledForUserId: String,
        dataStore: DataStore,
        currencyManager: CurrencyManager? = nil
    ) async {
        guard canRecordSettlements else {
            errorMessage = String(localized: "settlement.offline.approximate")
            return
        }
        do {
            try await txMemberRepo.delete(
                transactionId: transactionId,
                settledForUserId: settledForUserId
            )
            await load(
                sharedAccountId: sharedAccountId,
                dataStore: dataStore,
                currencyManager: currencyManager
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Bulk action: marks every non-payer member's share of a txn as
    /// settled (or unmarks all if already fully closed). Mirrors the
    /// "Учесть всё" / "Вернуть всё" button in the per-txn sheet — and
    /// the quick toggle on the row when the user is OK collapsing the
    /// per-member detail.
    ///
    /// `payerUserId` is the user whose personal account funded the
    /// auto-transfer for this txn — they can't owe themselves their own
    /// share, so we never mark a row for them.
    func markTxnSettledForAll(
        transactionId: String,
        sharedAccountId: String,
        payerUserId: String,
        memberUserIds: [String],
        dataStore: DataStore,
        currencyManager: CurrencyManager? = nil
    ) async {
        guard canRecordSettlements else {
            errorMessage = String(localized: "settlement.offline.approximate")
            return
        }
        do {
            let me = try await SupabaseManager.shared.currentUserId()
            let alreadySettled = memberSettlementsByTxn[transactionId] ?? []
            let toMark = memberUserIds
                .filter { $0 != payerUserId }
                .filter { !alreadySettled.contains($0) }
            // Collect insert failures instead of swallowing them with `try?`.
            // A silent failure here is exactly what made "marked settled, then
            // it re-appears" invisible — the row never persisted but the UI
            // gave no signal. Surface the last error after the reload.
            var lastError: Error?
            for member in toMark {
                let input = CreateTransactionMemberSettlementInput(
                    transaction_id: transactionId,
                    shared_account_id: sharedAccountId,
                    settled_for_user_id: member,
                    settled_by_user_id: me,
                    note: nil
                )
                do {
                    _ = try await txMemberRepo.create(input)
                } catch {
                    lastError = error
                    AppLogger.data.error("markTxnSettledForAll insert failed: \(error.localizedDescription)")
                }
            }
            await load(
                sharedAccountId: sharedAccountId,
                dataStore: dataStore,
                currencyManager: currencyManager
            )
            if let lastError { errorMessage = lastError.localizedDescription }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Inverse of `markTxnSettledForAll` — clears every per-member mark on
    /// a txn, reopening it. Useful when the user toggles ✓→◯ on the row.
    func unmarkTxnSettledForAll(
        transactionId: String,
        sharedAccountId: String,
        dataStore: DataStore,
        currencyManager: CurrencyManager? = nil
    ) async {
        guard canRecordSettlements else {
            errorMessage = String(localized: "settlement.offline.approximate")
            return
        }
        let toClear = transactionMemberSettlements
            .filter { $0.transactionId == transactionId }
        for s in toClear {
            try? await txMemberRepo.delete(id: s.id)
        }
        await load(
            sharedAccountId: sharedAccountId,
            dataStore: dataStore,
            currencyManager: currencyManager
        )
    }

    /// Past settlements across ALL periods for this view-model's most
    /// recent `load()` call, filtered to the currently-selected period
    /// regardless of whether `balances` is empty. Used to power the
    /// "orphan cleanup" affordance (P3) — when all source transactions
    /// have been deleted but the settlement rows remain.
    ///
    /// Different from `pastSettlementsForCurrentPeriod` only in intent:
    /// both lists contain the same rows at runtime. Keeping a named
    /// alias so the UI contract reads clearly when we intentionally
    /// surface the list during the empty state.
    var pastSettlementsForCurrentPeriodIgnoredOrphans: [Settlement] {
        pastSettlementsForCurrentPeriod
    }

    /// Removes all past settlements whose `period_end` falls inside the
    /// currently-selected period. Used by the "Clear settled records"
    /// affordance when `balances` is empty but stale settlement rows
    /// remain (e.g. user closed debts, then deleted the underlying
    /// transactions). Only rows the current user created can be
    /// deleted per RLS; failures on individual rows are swallowed so
    /// a partial cleanup doesn't block the rest.
    func cleanOrphanSettlements(
        sharedAccountId: String,
        dataStore: DataStore,
        currencyManager: CurrencyManager? = nil
    ) async {
        let stale = pastSettlementsForCurrentPeriod
        guard !stale.isEmpty else { return }
        for s in stale {
            do {
                try await settlementRepo.delete(id: s.id)
            } catch {
                // Creator-only RLS; swallow per-row errors but surface
                // the last one so the user knows something didn't go.
                errorMessage = error.localizedDescription
            }
        }
        await load(
            sharedAccountId: sharedAccountId,
            dataStore: dataStore,
            currencyManager: currencyManager
        )
    }
}
