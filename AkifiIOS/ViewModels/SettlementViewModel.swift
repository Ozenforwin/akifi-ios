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

    func dateInterval(reference: Date = Date()) -> DateInterval {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
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
@MainActor
@Observable
final class SettlementViewModel {
    var selectedPeriod: SettlementPeriod = .thisMonth

    var balances: [SettlementCalculator.MemberBalance] = []
    var suggestions: [SettlementCalculator.SettlementSuggestion] = []
    var pastSettlements: [Settlement] = []
    var isLoading = false
    var errorMessage: String?

    private let settlementRepo = SettlementRepository()
    private let supabase = SupabaseManager.shared.client

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

        // Pull canonical member list from `account_members` (falls back to
        // transaction-authors if the network call fails — keeps legacy
        // behavior for accounts without the join). Read split_weight at
        // the same time so the settlement math can honor per-member shares.
        var members: [AccountMember] = []
        do {
            members = try await supabase
                .from("account_members")
                .select()
                .eq("account_id", value: sharedAccountId)
                .execute()
                .value
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

        let interval = selectedPeriod.dateInterval()

        // Fetch past settlements BEFORE compute so closed debts are applied
        // to balances and don't show up again as live suggestions.
        do {
            pastSettlements = try await settlementRepo.fetchForAccount(sharedAccountId)
        } catch {
            errorMessage = error.localizedDescription
        }

        // Settlement balances are surfaced in the user's selected display
        // currency, NOT the shared account's stored currency. Otherwise a
        // mixed-currency account (e.g. «Семейный» tagged VND but full of
        // RUB rows) yields totals in VND that the UI then prints with a ₽
        // symbol — exactly the "78 000 ₽" / 156 000 ₫ confusion the user
        // reported. By telling the calculator that the base IS the display
        // currency, every contribution is FX-normalized to RUB at compute
        // time and the rendered numbers match the symbol.
        let fxRates = currencyManager?.rates ?? [:]
        let baseCurrency = currencyManager?.dataCurrency.rawValue ?? "RUB"

        balances = SettlementCalculator.compute(
            sharedAccountId: sharedAccountId,
            transactions: dataStore.transactions,
            memberUserIds: memberUserIds,
            personalAccountsByUser: personalMap,
            period: interval,
            pastSettlements: pastSettlements,
            memberWeights: memberWeights,
            fxRates: fxRates,
            baseCurrency: baseCurrency
        )
        suggestions = SettlementCalculator.settlements(from: balances)

        isLoading = false
    }

    /// Past settlements filtered to the currently selected period — used by
    /// the "История расчётов" section of the card.
    var pastSettlementsForCurrentPeriod: [Settlement] {
        let interval = selectedPeriod.dateInterval()
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        return pastSettlements.filter { s in
            guard let end = parser.date(from: s.periodEnd) else { return false }
            return interval.contains(end)
        }
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
        do {
            let user = try await SupabaseManager.shared.currentUserId()
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(identifier: "UTC")
            fmt.dateFormat = "yyyy-MM-dd"
            let interval = selectedPeriod.dateInterval()

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
