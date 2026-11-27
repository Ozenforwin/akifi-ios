import Foundation
import Observation
import UserNotifications
@preconcurrency import Supabase

/// App-wide «Долги» state — owned by `AppViewModel`, shared by the Home
/// card, Net Worth and the Debts screens.
///
/// Balances: `debts_summary` (server) when it is newer than every local
/// write and refresh, otherwise the local balance of the debt account —
/// which already has this device's own, possibly still queued, movements
/// (contract §A4 offline fallback). Details (due date, closed, note) are
/// the summary's, cached on disk per user for offline starts.
@Observable @MainActor
final class DebtsStore {
    private(set) var summary: DebtsSummary?
    private(set) var isLoading = false
    /// The last refresh failed (offline): numbers are local.
    private(set) var isOffline = false

    @ObservationIgnored private var summaryUserId: String?
    @ObservationIgnored private var summaryFetchedAt: Date?
    /// `DataStore.mutationGeneration` when the summary arrived.
    @ObservationIgnored private var summaryMutationMark: UInt64?

    /// Network seam (tests replace it).
    struct Remote: Sendable {
        var fetchSummary: @Sendable () async throws -> DebtsSummary
        var create: @Sendable (CreateDebtParams) async throws -> String
        var updateDetails: @Sendable (_ accountId: String, DebtDetailsPatch) async throws -> Void
        var rename: @Sendable (_ accountId: String, _ name: String) async throws -> Void
        var setClosed: @Sendable (_ accountId: String, _ closed: Bool) async throws -> Void
        var delete: @Sendable (_ accountId: String) async throws -> Void
        var currentUserId: @Sendable () async throws -> String

        static let live = Remote(
            fetchSummary: { try await DebtRepository().fetchSummary() },
            create: { try await DebtRepository().create($0) },
            updateDetails: { try await DebtRepository().updateDetails(accountId: $0, $1) },
            rename: { try await DebtRepository().renameAccount(accountId: $0, name: $1) },
            setClosed: { try await DebtRepository().setClosed(accountId: $0, closed: $1) },
            delete: { try await DebtRepository().delete(accountId: $0) },
            currentUserId: { try await SupabaseManager.shared.currentUserId() }
        )
    }

    @ObservationIgnored var remote: Remote = .live
    /// Side effects of reminders (tests replace it).
    @ObservationIgnored var reminders: DebtReminderScheduler = .live

    // MARK: - Reading

    /// Every debt (open first), merged as described on the type.
    func entries(dataStore: DataStore, today: String = DebtMath.localToday()) -> [DebtEntry] {
        DebtMath.merge(
            summary: summaryFor(dataStore),
            debtAccounts: dataStore.debtAccounts,
            transactions: dataStore.transactions,
            preferServerBalance: prefersServerBalance(dataStore),
            today: today
        )
    }

    func entry(accountId: String, dataStore: DataStore) -> DebtEntry? {
        entries(dataStore: dataStore).first { $0.accountId == accountId }
    }

    /// Open debts per currency.
    func totals(dataStore: DataStore) -> [DebtsSummary.Total] {
        DebtMath.totals(entries(dataStore: dataStore))
    }

    private func summaryFor(_ dataStore: DataStore) -> DebtsSummary? {
        guard let summary else { return nil }
        // Never show another user's summary.
        if let viewer = dataStore.profile?.id, let owner = summaryUserId, viewer.lowercased() != owner { return nil }
        return summary
    }

    /// The server balance wins only when the summary is newer than every
    /// local write and every full refresh of the transactions.
    func prefersServerBalance(_ dataStore: DataStore) -> Bool {
        guard summary != nil, let fetchedAt = summaryFetchedAt,
              summaryMutationMark == dataStore.mutationGeneration else { return false }
        if let loaded = dataStore.lastCompleteLoadAt, loaded > fetchedAt { return false }
        return true
    }

    // MARK: - Loading

    func refresh(dataStore: DataStore) async {
        let viewer = dataStore.profile?.id.lowercased()
        if summary == nil, let viewer { loadCached(userId: viewer) }
        isLoading = true
        defer { isLoading = false }
        let mark = dataStore.mutationGeneration
        do {
            let fetched = try await remote.fetchSummary()
            apply(fetched, userId: viewer, mutationMark: mark)
            isOffline = false
            logMismatches(dataStore: dataStore)
        } catch {
            isOffline = true
            AppLogger.data.info("debts_summary unavailable, local balances: \(error.localizedDescription)")
        }
        await rescheduleReminders(dataStore: dataStore)
    }

    /// Installs a summary (internal so tests and previews can seed it).
    func apply(_ fetched: DebtsSummary, userId: String?, mutationMark: UInt64?, at date: Date = Date()) {
        if fetched != summary { summary = fetched }
        summaryUserId = userId
        summaryFetchedAt = date
        summaryMutationMark = mutationMark
        if let userId { Self.cache(fetched, userId: userId) }
    }

    func reset() {
        summary = nil
        summaryUserId = nil
        summaryFetchedAt = nil
        summaryMutationMark = nil
        isOffline = false
    }

    /// Server vs local disagreeing while both are complete and fresh is a
    /// data bug worth hearing about (like `settlement_integrity_mismatch`).
    private func logMismatches(dataStore: DataStore) {
        guard prefersServerBalance(dataStore), let summary, dataStore.lastCompleteLoadAt != nil else { return }
        let local = Dictionary(dataStore.debtAccounts.map { ($0.id.lowercased(), DebtMath.balance(of: $0, transactions: dataStore.transactions)) },
                               uniquingKeysWith: { first, _ in first })
        let diffs = summary.debts.compactMap { entry -> Int64? in
            guard let mine = local[entry.accountId.lowercased()], mine != entry.balance else { return nil }
            return abs(mine - entry.balance)
        }
        guard let worst = diffs.max() else { return }
        AppLogger.data.error("debt balance mismatch: server vs local differ by \(worst) minor units on \(diffs.count, privacy: .public) debts")
        AnalyticsService.logEvent("debt_balance_mismatch", params: [
            "diff_bucket": AnalyticsService.magnitudeBucket(worst),
            "debts": diffs.count,
        ])
    }

    // MARK: - Cache (offline start)

    private struct Cached: Codable, Sendable { let userId: String; let summary: DebtsSummary }
    private static let cacheFile = "debts_summary.json"

    private func loadCached(userId: String) {
        guard let cached = PersistenceManager.shared.load(Cached.self, filename: Self.cacheFile),
              cached.userId == userId else { return }
        summary = cached.summary
        summaryUserId = userId
        // Never "fresh": the balances stay local until the next fetch.
        summaryFetchedAt = nil
        summaryMutationMark = nil
    }

    private static func cache(_ summary: DebtsSummary, userId: String) {
        PersistenceManager.shared.saveInBackground(Cached(userId: userId, summary: summary), filename: cacheFile)
    }

    // MARK: - Writing

    /// Form input for a new person.
    struct NewDebt: Equatable, Sendable {
        var name: String
        var currency: String
        var contact: String?
        var dueDate: String?
        var remind: Bool
        var note: String?
    }

    /// `create_debt`, then the local account so the screens show it at
    /// once (balance 0 — «в расчёте» — until the first movement).
    @discardableResult
    func createDebt(_ new: NewDebt, dataStore: DataStore) async throws -> Account {
        let params = CreateDebtParams.make(
            name: new.name, currency: new.currency, contact: new.contact,
            dueDate: new.dueDate, remind: new.remind, note: new.note
        )
        let userId = try await remote.currentUserId()
        let id = try await remote.create(params)
        let account = Account(
            id: id, userId: userId.lowercased(), name: params.p_name ?? params.p_counterparty_name,
            icon: params.p_icon ?? DebtDefaults.icon, color: params.p_color ?? DebtDefaults.color,
            initialBalance: 0, isPrimary: false, currency: params.p_currency,
            accountType: .debt, createdAt: AppDateFormatters.nowTimestamp()
        )
        if dataStore.account(withId: account.id) == nil {
            dataStore.allAccounts.append(account)
            dataStore.rebuildCaches()
        }
        // The new debt's details: optimistic summary row until the refetch.
        insertOptimistic(DebtsSummary.Entry(
            accountId: account.id, name: account.name, icon: account.icon, color: account.color,
            currency: account.currency, balance: 0, counterpartyName: params.p_counterparty_name,
            counterpartyContact: params.p_counterparty_contact, dueDate: params.p_due_date,
            remind: params.p_remind, note: params.p_note, createdAt: account.createdAt
        ), userId: userId.lowercased())
        return account
    }

    private func insertOptimistic(_ entry: DebtsSummary.Entry, userId: String) {
        var debts = summary?.debts ?? []
        debts.removeAll { $0.accountId.lowercased() == entry.accountId.lowercased() }
        debts.append(entry)
        summary = DebtsSummary(version: summary?.version ?? 1, today: summary?.today, debts: debts, totals: summary?.totals ?? [])
        summaryUserId = userId
        // Optimistic rows never make the server balance authoritative.
        summaryMutationMark = nil
    }

    /// A movement ready to write: both legs built with real quotes, and the
    /// exact change of the debt balance (for the sign-flip confirmation).
    struct PreparedMovement: Sendable {
        let action: DebtAction
        let legs: DebtTransferBuilder.Legs
        /// The debt leg's amount, minor units of the debt currency.
        let debtAmountMinor: Int64
    }

    /// Builds one of the four actions without writing anything (a missing
    /// FX quote throws here, before any row exists).
    func prepare(
        _ action: DebtAction,
        amount: Decimal,
        entryCurrency: CurrencyCode,
        debtAccount: Account,
        realAccount: Account,
        counterpartyName: String,
        date: Date,
        comment: String?,
        currencyManager: CurrencyManager
    ) async throws -> PreparedMovement {
        let rates = await currencyManager.ratesForWrite([
            entryCurrency.code, debtAccount.currencyCode.code, realAccount.currencyCode.code,
        ])
        let userId = try await remote.currentUserId()
        let legs = try DebtTransferBuilder.legs(
            action: action, amount: amount, entryCurrency: entryCurrency,
            debtAccount: debtAccount, realAccount: realAccount, rates: rates,
            userId: userId, date: TransactionFormDates.string(from: date),
            counterpartyName: counterpartyName, comment: comment
        )
        let debtLeg = action.movesIntoDebt ? legs.income : legs.expense
        return PreparedMovement(action: action, legs: legs, debtAmountMinor: debtLeg.amount_native.kopecks)
    }

    /// Writes both legs through the regular transfer path
    /// (`DataStore.addTransaction`: client ids, offline queue, placeholders).
    func commit(_ movement: PreparedMovement, dataStore: DataStore) async throws {
        _ = try await dataStore.addTransaction(movement.legs.expense)
        _ = try await dataStore.addTransaction(movement.legs.income)
        AnalyticsService.logEvent("debt_movement", params: ["action": movement.action.rawValue])
        await refresh(dataStore: dataStore)
    }

    /// `prepare` + `commit` in one go (no confirmation step).
    func record(
        _ action: DebtAction,
        amount: Decimal,
        entryCurrency: CurrencyCode,
        debtAccount: Account,
        realAccount: Account,
        counterpartyName: String,
        date: Date,
        comment: String?,
        dataStore: DataStore,
        currencyManager: CurrencyManager
    ) async throws {
        let prepared = try await prepare(
            action, amount: amount, entryCurrency: entryCurrency, debtAccount: debtAccount,
            realAccount: realAccount, counterpartyName: counterpartyName, date: date,
            comment: comment, currencyManager: currencyManager
        )
        try await commit(prepared, dataStore: dataStore)
    }

    /// Edits an existing movement in place (both legs, like
    /// `TransferFormView`): amount, real account, date, comment.
    func updateMovement(
        _ leg: Transaction,
        amount: Decimal,
        entryCurrency: CurrencyCode,
        debtAccount: Account,
        realAccount: Account,
        counterpartyName: String,
        date: Date,
        comment: String?,
        dataStore: DataStore,
        currencyManager: CurrencyManager
    ) async throws {
        guard let group = leg.manualTransferGroupId else { throw DebtTransferError.notADebtAccount }
        let legs = dataStore.transactions.filter { $0.isManualTransferLeg(ofGroup: group) }
        guard let debtLeg = legs.first(where: { $0.accountId == debtAccount.id }) else { throw DebtTransferError.notADebtAccount }
        let realLeg = legs.first { $0.id != debtLeg.id }
        let action: DebtAction = debtLeg.type == .income ? .lend : .borrow   // direction only
        let rates = await currencyManager.ratesForWrite([
            entryCurrency.code, debtAccount.currencyCode.code, realAccount.currencyCode.code,
        ])
        let userId = try await remote.currentUserId()
        let built = try DebtTransferBuilder.legs(
            action: action, amount: amount, entryCurrency: entryCurrency,
            debtAccount: debtAccount, realAccount: realAccount, rates: rates,
            userId: userId, date: TransactionFormDates.string(from: date),
            counterpartyName: counterpartyName, comment: comment, groupId: group
        )
        let newDebt = action.movesIntoDebt ? built.income : built.expense
        let newReal = action.movesIntoDebt ? built.expense : built.income
        try await dataStore.updateTransaction(id: debtLeg.id, Self.update(from: newDebt))
        if let realLeg {
            try await dataStore.updateTransaction(id: realLeg.id, Self.update(from: newReal))
        }
        await refresh(dataStore: dataStore)
    }

    nonisolated static func update(from input: CreateTransactionInput) -> UpdateTransactionInput {
        UpdateTransactionInput(
            amount: input.amount,
            amount_native: input.amount_native,
            currency: input.currency,
            foreign_amount: input.foreign_amount,
            foreign_currency: input.foreign_currency,
            fx_rate: input.fx_rate,
            date: input.date,
            description: input.description,
            merchant_name: input.merchant_name,
            account_id: input.account_id,
            replaceCurrencyFields: true
        )
    }

    /// «Погасить» my personal debt to a shared account (contract §B5).
    func repayPersonalDebt(
        amount: Decimal,
        entryCurrency: CurrencyCode,
        sharedAccount: Account,
        fromAccount: Account,
        date: Date,
        dataStore: DataStore,
        currencyManager: CurrencyManager
    ) async throws {
        let rates = await currencyManager.ratesForWrite([
            entryCurrency.code, sharedAccount.currencyCode.code, fromAccount.currencyCode.code,
        ])
        let userId = try await remote.currentUserId()
        let legs = try DebtTransferBuilder.personalRepaymentLegs(
            amount: amount, entryCurrency: entryCurrency, sharedAccount: sharedAccount,
            fromAccount: fromAccount, rates: rates, userId: userId,
            date: TransactionFormDates.string(from: date)
        )
        _ = try await dataStore.addTransaction(legs.expense)
        _ = try await dataStore.addTransaction(legs.income)
        AnalyticsService.logEvent("personal_debt_repaid")
    }

    func updateDetails(accountId: String, name: String, contact: String?, dueDate: String?, remind: Bool, note: String?, dataStore: DataStore) async throws {
        let patch = DebtDetailsPatch(name: name, contact: contact, dueDate: dueDate, remind: remind, note: note)
        try await remote.updateDetails(accountId, patch)
        if let account = dataStore.account(withId: accountId), account.name != patch.counterparty_name {
            try await remote.rename(accountId, patch.counterparty_name)
        }
        await refresh(dataStore: dataStore)
    }

    func setClosed(accountId: String, closed: Bool, dataStore: DataStore) async throws {
        try await remote.setClosed(accountId, closed)
        await refresh(dataStore: dataStore)
    }

    /// Deletes the person (contract §A6: legs on real accounts stay).
    func delete(accountId: String, dataStore: DataStore) async throws {
        try await remote.delete(accountId)
        dataStore.allAccounts.removeAll { $0.id == accountId }
        dataStore.transactions.removeAll { $0.accountId == accountId }
        dataStore.rebuildCaches()
        if let summary {
            self.summary = DebtsSummary(version: summary.version, today: summary.today,
                                        debts: summary.debts.filter { $0.accountId != accountId }, totals: summary.totals)
        }
        await reminders.cancel([DebtReminderPlanner.identifier(accountId: accountId)])
        await dataStore.loadAll()
    }

    // MARK: - Reminders

    func rescheduleReminders(dataStore: DataStore) async {
        let userId = dataStore.profile?.id
        let enabled = userId.flatMap { NotificationPreferencesCache.settings(userId: $0)?.enabled } ?? NotificationSettings.defaults.enabled
        let plan = DebtReminderPlanner.plan(entries(dataStore: dataStore), notificationsEnabled: enabled)
        await reminders.apply(plan)
    }
}

/// Side effects of debt reminders (`UNUserNotificationCenter`).
struct DebtReminderScheduler: Sendable {
    var pendingIdentifiers: @Sendable () async -> [String]
    var schedule: @Sendable (DebtReminderPlanner.Reminder) async -> Void
    var cancel: @Sendable ([String]) async -> Void

    func apply(_ plan: [DebtReminderPlanner.Reminder]) async {
        let pending = await pendingIdentifiers()
        let stale = DebtReminderPlanner.toCancel(pendingIdentifiers: pending, plan: plan)
        if !stale.isEmpty { await cancel(stale) }
        for reminder in plan { await schedule(reminder) }
    }

    static let live = DebtReminderScheduler(
        pendingIdentifiers: {
            await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier)
        },
        schedule: { reminder in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .denied: return
            case .notDetermined:
                _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
            default: break
            }
            let id = DebtReminderPlanner.identifier(accountId: reminder.accountId)
            let content = UNMutableNotificationContent()
            content.title = String(localized: "debts.reminder.title")
            content.body = reminder.balance > 0
                ? String(localized: "debts.reminder.body.owedToMe \(reminder.name)")
                : String(localized: "debts.reminder.body.iOwe \(reminder.name)")
            content.sound = .default
            content.userInfo = ["debt_account_id": reminder.accountId]
            let comps = AppDateFormatters.localCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.fireDate)
            let request = UNNotificationRequest(
                identifier: id, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            )
            center.removePendingNotificationRequests(withIdentifiers: [id])
            try? await center.add(request)
        },
        cancel: { ids in
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
    )
}
