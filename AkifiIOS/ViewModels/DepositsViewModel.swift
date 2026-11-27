import Foundation
import Observation

/// Observable facade over the deposits feature. Owns the deposits list,
/// contributions-by-deposit map, and CRUD + maturity flows exposed to the
/// UI. Created once by `DepositListView` (via `@State`).
///
/// # Responsibilities
/// - Load deposits + contributions on demand.
/// - Detect auto-maturity on each `load()` (any active deposit with
///   `endDate <= today` gets matured automatically).
/// - Orchestrate the 4-row atomic create: Account → Deposit → Contribution
///   → transfer pair.
/// - Contribute (add top-up lot) → transfer pair + contribution row.
/// - Close early → interest transaction + transfer pair to return_to.
/// - Expose live accrued interest (computed, not stored).
///
/// # Concurrency
/// `@MainActor` + `@Observable`. All network calls are awaited on the main
/// actor, matching how `NetWorthViewModel` and `SettlementViewModel` work.
/// Why a close / maturity didn't run (V1).
enum DepositCloseError: LocalizedError, Equatable {
    /// A close of the same deposit is already in flight.
    case alreadyClosing
    /// The deposit's contributions didn't load — closing now would pay out
    /// nothing and mark it closed.
    case contributionsNotLoaded

    var errorDescription: String? {
        switch self {
        case .alreadyClosing: String(localized: "deposit.error.alreadyClosing")
        case .contributionsNotLoaded: String(localized: "deposit.error.contributionsNotLoaded")
        }
    }
}

/// `TransactionRepository.createOnce` under the `create` name the payout
/// code calls (see `DepositsViewModel.writePayout`).
private struct PayoutWriter {
    let base: TransactionRepository

    func create(_ input: CreateTransactionInput) async throws -> Transaction {
        try await base.createOnce(input).row
    }
}

@MainActor
@Observable
final class DepositsViewModel {
    var deposits: [Deposit] = []
    var contributionsByDeposit: [String: [DepositContribution]] = [:]
    var isLoading = false
    var errorMessage: String?

    private let depositRepo = DepositRepository()
    private let contributionRepo = DepositContributionRepository()
    private let accountRepo = AccountRepository()
    private let transactionRepo = TransactionRepository()

    // MARK: - Load

    /// Fetches deposits + every deposit's contributions in parallel, then
    /// auto-matures any that have hit their `endDate`.
    func load(dataStore: DataStore) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            deposits = try await depositRepo.fetchAll()
        } catch {
            errorMessage = error.localizedDescription
            AppLogger.data.warning("deposits fetch: \(error.localizedDescription)")
            return
        }

        // Fetch contributions for every deposit in parallel. A failed fetch
        // is remembered: that deposit's numbers are unknown, so it is never
        // auto-matured (it would be marked "matured" with no payout).
        var failures: Set<String> = []
        var firstFailure: String?
        await withTaskGroup(of: (String, Result<[DepositContribution], any Error>).self) { group in
            for d in deposits {
                group.addTask { [contributionRepo] in
                    do { return (d.id, .success(try await contributionRepo.fetchForDeposit(d.id))) }
                    catch { return (d.id, .failure(error)) }
                }
            }
            for await (depositId, result) in group {
                switch result {
                case .success(let list):
                    contributionsByDeposit[depositId] = list
                case .failure(let error):
                    failures.insert(depositId)
                    firstFailure = firstFailure ?? error.localizedDescription
                    AppLogger.data.warning("deposit contributions fetch: \(error.localizedDescription)")
                }
            }
        }
        contributionLoadFailures = failures
        if let firstFailure { errorMessage = firstFailure }

        // Auto-maturity pass. Iterate over a snapshot; `matureDeposit`
        // mutates `deposits` in place.
        let today = InterestCalculator.defaultCalendar.startOfDay(for: Date())
        let snapshot = deposits
        for deposit in snapshot where Self.shouldAutoMature(
            deposit,
            today: today,
            contributionsLoaded: hasLoadedContributions(deposit.id),
            isClosing: closingDepositIds.contains(deposit.id)
        ) {
            await matureDeposit(deposit, dataStore: dataStore)
        }
    }

    // MARK: - Close guards (V1)

    /// Deposits whose close / maturity is in flight. The screens disable
    /// the close actions for them, and a second call is rejected — while
    /// the 4+ requests of a payout run, "Close early" stayed enabled and a
    /// second tap (or a pull-to-refresh re-running auto-maturity) wrote a
    /// second interest row and a second return transfer.
    private(set) var closingDepositIds: Set<String> = []

    /// Deposits whose contributions failed to load in the last `load()`.
    private(set) var contributionLoadFailures: Set<String> = []

    func isClosing(_ deposit: Deposit) -> Bool {
        closingDepositIds.contains(deposit.id)
    }

    /// Claims the close of `depositId`; false when one is already running.
    func beginClosing(_ depositId: String) -> Bool {
        closingDepositIds.insert(depositId).inserted
    }

    func endClosing(_ depositId: String) {
        closingDepositIds.remove(depositId)
    }

    /// Contributions are known for this deposit — loaded, and the last
    /// load didn't fail for it. Principal and interest of a close are
    /// computed from them; without them a close would pay out 0.
    func hasLoadedContributions(_ depositId: String) -> Bool {
        contributionsByDeposit[depositId] != nil && !contributionLoadFailures.contains(depositId)
    }

    /// Auto-maturity rule: an active term deposit whose end day has come,
    /// with its contributions loaded and no close already in flight.
    nonisolated static func shouldAutoMature(
        _ deposit: Deposit,
        today: Date,
        contributionsLoaded: Bool,
        isClosing: Bool
    ) -> Bool {
        guard deposit.status == .active, contributionsLoaded, !isClosing,
              let endDateStr = deposit.endDate,
              let endDate = parseDate(endDateStr) else { return false }
        return endDate <= today
    }

    /// Client ids of the payout rows of one deposit. A deposit is closed
    /// once, so its payout rows are derived from its id: a retry after a
    /// half-written payout finds the rows the first attempt wrote (23505)
    /// instead of writing a second interest row or return transfer.
    struct PayoutIds: Equatable, Sendable {
        let interest: String
        let returnOut: String
        let returnIn: String
        let transferGroup: String
    }

    nonisolated static func payoutIds(depositId: String) -> PayoutIds {
        PayoutIds(
            interest: DeterministicUUID.make("deposit-payout", depositId, "interest"),
            returnOut: DeterministicUUID.make("deposit-payout", depositId, "return-out"),
            returnIn: DeterministicUUID.make("deposit-payout", depositId, "return-in"),
            transferGroup: DeterministicUUID.make("deposit-payout", depositId, "transfer-group")
        )
    }

    // MARK: - Create

    /// Create a new deposit with its first contribution. Atomic-ish (we
    /// create 4 rows sequentially; full atomicity would need a server RPC).
    ///
    /// Side effects:
    /// 1. Create a new `Account` with `account_type = .deposit`.
    /// 2. Create the `Deposit` row linked to that account.
    /// 3. Create a transfer pair (from `sourceAccount` → new deposit
    ///    account) via the TransferFormView pattern.
    /// 4. Insert the first `DepositContribution` row referencing the
    ///    transfer group.
    ///
    /// On any failure after step 1, partial state is left behind. The
    /// caller (UI) should `loadAll` on DataStore to reflect reality.
    func create(
        name: String,
        currency: CurrencyCode,
        rate: Decimal,
        frequency: CompoundFrequency,
        startDate: Date,
        endDate: Date?,
        initialAmount: Int64,
        sourceAccount: Account,
        sourceAmount: Int64?,
        fxRate: Decimal?,
        returnToAccountId: String?,
        dataStore: DataStore,
        currencyManager: CurrencyManager
    ) async throws {
        let userId = try await SupabaseManager.shared.currentUserId()

        // 1. Account
        let account = try await accountRepo.create(
            name: name,
            icon: "percent",
            color: "#A78BFA",
            initialBalance: 0,
            currency: currency.code,
            accountType: .deposit
        )

        // 2. Deposit
        let depositInput = CreateDepositInput(
            user_id: userId,
            account_id: account.id,
            interest_rate: rate,
            compound_frequency: frequency.rawValue,
            start_date: Self.formatDate(startDate),
            end_date: endDate.map(Self.formatDate),
            return_to_account_id: returnToAccountId ?? sourceAccount.id,
            notes: nil
        )
        let deposit = try await depositRepo.create(depositInput)

        // 3. Transfer pair (source → deposit account) for initial amount.
        let groupId = UUID().uuidString
        let dateStr = Self.formatDate(startDate)
        let isSameCurrency = sourceAccount.currency.uppercased() == currency.code.uppercased()
        let sourceAmountKopecks = isSameCurrency ? initialAmount : (sourceAmount ?? initialAmount)
        let sourceAmountDecimal = Decimal(sourceAmountKopecks) / 100
        let destAmountDecimal = Decimal(initialAmount) / 100

        // ADR-001: each transfer leg lives on its own account, so
        // `amount_native == amount` (in the leg's own currency) and
        // `currency = account.currency`. No foreign_* fields — the user
        // entered each side in that side's native currency (the split
        // between source/destination IS the cross-currency conversion,
        // captured in the `DepositContribution` row's fx_rate).

        // Expense leg on source account (in source currency).
        _ = try await transactionRepo.create(CreateTransactionInput(
            user_id: userId,
            account_id: sourceAccount.id,
            amount: sourceAmountDecimal,
            amount_native: sourceAmountDecimal,
            currency: sourceAccount.currency.uppercased(),
            type: TransactionType.expense.rawValue,
            date: dateStr,
            description: String(localized: "deposit.transfer.contribute"),
            category_id: nil,
            merchant_name: name,
            transfer_group_id: groupId
        ))
        // Income leg on deposit account (in deposit currency).
        _ = try await transactionRepo.create(CreateTransactionInput(
            user_id: userId,
            account_id: account.id,
            amount: destAmountDecimal,
            amount_native: destAmountDecimal,
            currency: currency.code.uppercased(),
            type: TransactionType.income.rawValue,
            date: dateStr,
            description: String(localized: "deposit.transfer.contribute"),
            category_id: nil,
            merchant_name: name,
            transfer_group_id: groupId
        ))

        // 4. Contribution row.
        let contribution = try await contributionRepo.create(CreateDepositContributionInput(
            user_id: userId,
            deposit_id: deposit.id,
            amount: initialAmount,
            contributed_at: dateStr,
            source_account_id: sourceAccount.id,
            source_currency: isSameCurrency ? nil : sourceAccount.currency,
            source_amount: isSameCurrency ? nil : sourceAmountKopecks,
            fx_rate: isSameCurrency ? nil : fxRate,
            transfer_group_id: groupId
        ))

        // Local state.
        deposits.insert(deposit, at: 0)
        contributionsByDeposit[deposit.id] = [contribution]

        // Refresh DataStore so the new account + transactions appear
        // in Home / Net Worth without a cold reload.
        await dataStore.loadAll()
    }

    // MARK: - Contribute (top up)

    /// Add a new contribution lot to an active deposit. Creates a
    /// transfer pair + contribution row. Accrued interest auto-recomputes
    /// on next render because the new lot starts its own compounding clock.
    func contribute(
        to deposit: Deposit,
        depositAccount: Account,
        amountInDeposit: Int64,
        sourceAccount: Account,
        sourceAmount: Int64?,
        fxRate: Decimal?,
        dataStore: DataStore
    ) async throws {
        let userId = try await SupabaseManager.shared.currentUserId()
        let groupId = UUID().uuidString
        let dateStr = Self.formatDate(Date())

        let isSameCurrency = sourceAccount.currency.uppercased() == depositAccount.currency.uppercased()
        let sourceAmountKopecks = isSameCurrency ? amountInDeposit : (sourceAmount ?? amountInDeposit)
        let sourceAmountDecimal = Decimal(sourceAmountKopecks) / 100
        let destAmountDecimal = Decimal(amountInDeposit) / 100

        // ADR-001 (see `create()` above for the same rationale): each leg
        // is already in its own account's currency, so `amount_native = amount`.
        _ = try await transactionRepo.create(CreateTransactionInput(
            user_id: userId,
            account_id: sourceAccount.id,
            amount: sourceAmountDecimal,
            amount_native: sourceAmountDecimal,
            currency: sourceAccount.currency.uppercased(),
            type: TransactionType.expense.rawValue,
            date: dateStr,
            description: String(localized: "deposit.transfer.contribute"),
            category_id: nil,
            merchant_name: depositAccount.name,
            transfer_group_id: groupId
        ))
        _ = try await transactionRepo.create(CreateTransactionInput(
            user_id: userId,
            account_id: depositAccount.id,
            amount: destAmountDecimal,
            amount_native: destAmountDecimal,
            currency: depositAccount.currency.uppercased(),
            type: TransactionType.income.rawValue,
            date: dateStr,
            description: String(localized: "deposit.transfer.contribute"),
            category_id: nil,
            merchant_name: depositAccount.name,
            transfer_group_id: groupId
        ))

        let contribution = try await contributionRepo.create(CreateDepositContributionInput(
            user_id: userId,
            deposit_id: deposit.id,
            amount: amountInDeposit,
            contributed_at: dateStr,
            source_account_id: sourceAccount.id,
            source_currency: isSameCurrency ? nil : sourceAccount.currency,
            source_amount: isSameCurrency ? nil : sourceAmountKopecks,
            fx_rate: isSameCurrency ? nil : fxRate,
            transfer_group_id: groupId
        ))

        contributionsByDeposit[deposit.id, default: []].append(contribution)
        await dataStore.loadAll()
    }

    // MARK: - Close early / mature

    /// Manually close a deposit before its `endDate`. Creates interest
    /// income transaction + transfer pair moving principal+accrued back to
    /// `returnTo`, then marks the deposit as `.closedEarly`.
    func closeEarly(
        _ deposit: Deposit,
        depositAccount: Account,
        returnTo: Account,
        dataStore: DataStore
    ) async throws {
        try await closeOrMature(
            deposit,
            depositAccount: depositAccount,
            returnTo: returnTo,
            newStatus: .closedEarly,
            dataStore: dataStore
        )
    }

    /// Auto-called from `load()` when `endDate <= today`. Moves funds to
    /// `returnToAccountId` and sets status to `.matured`.
    private func matureDeposit(_ deposit: Deposit, dataStore: DataStore) async {
        guard let depositAccount = dataStore.accounts.first(where: { $0.id == deposit.accountId }) else {
            return
        }
        let returnTo = dataStore.accounts.first { $0.id == deposit.returnToAccountId }
            ?? dataStore.accounts.first { $0.id != deposit.accountId }
        guard let returnTo else { return }
        do {
            try await closeOrMature(
                deposit,
                depositAccount: depositAccount,
                returnTo: returnTo,
                newStatus: .matured,
                dataStore: dataStore
            )
        } catch DepositCloseError.alreadyClosing {
            // Another call is paying this deposit out right now.
        } catch {
            AppLogger.data.warning("auto-mature failed for \(deposit.id): \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    /// Close / maturity, in an order that can neither pay twice nor mark a
    /// deposit closed without its payout (V1):
    /// 1. one close per deposit at a time (`beginClosing`), and only with
    ///    its contributions loaded;
    /// 2. the status flips FIRST and conditionally (`closeIfActive`: only
    ///    an active row changes). No row changed → an earlier tap or
    ///    another device closed it, nothing is paid;
    /// 3. the payout rows carry ids derived from the deposit
    ///    (`payoutIds`), so a retry after a partial failure reuses what the
    ///    first attempt wrote;
    /// 4. a payout that fails puts the deposit back to active, and the
    ///    error reaches the screen, so the user can retry.
    private func closeOrMature(
        _ deposit: Deposit,
        depositAccount: Account,
        returnTo: Account,
        newStatus: DepositStatus,
        dataStore: DataStore
    ) async throws {
        guard beginClosing(deposit.id) else { throw DepositCloseError.alreadyClosing }
        defer { endClosing(deposit.id) }
        guard hasLoadedContributions(deposit.id) else { throw DepositCloseError.contributionsNotLoaded }

        let closedAtStr = Self.formatDateTime(Date())
        guard let closed = try await depositRepo.closeIfActive(
            id: deposit.id,
            status: newStatus,
            closedAt: closedAtStr,
            returnToAccountId: returnTo.id
        ) else {
            // Not active any more: show the stored state, pay nothing.
            if let fresh = try? await depositRepo.fetchAll() { deposits = fresh }
            return
        }

        do {
            try await writePayout(deposit, depositAccount: depositAccount, returnTo: returnTo, dataStore: dataStore)
        } catch {
            do { try await depositRepo.reopen(id: deposit.id, from: newStatus) }
            catch { AppLogger.data.error("deposit reopen after failed payout: \(error.localizedDescription)") }
            await dataStore.loadAll()
            throw error
        }

        if let idx = deposits.firstIndex(where: { $0.id == deposit.id }) {
            deposits[idx] = closed
        }

        await dataStore.loadAll()
    }

    /// Interest income + return transfer of a close (step 3 above).
    private func writePayout(
        _ deposit: Deposit,
        depositAccount: Account,
        returnTo: Account,
        dataStore: DataStore
    ) async throws {
        let userId = try await SupabaseManager.shared.currentUserId()
        let contributions = contributionsByDeposit[deposit.id] ?? []
        // Interest runs to the end date, not to the day the app was opened.
        var accrued = InterestCalculator.accrueInterest(
            contributions: contributions,
            rate: deposit.interestRate,
            frequency: deposit.compoundFrequency,
            asOf: deposit.accrualCutoff(now: Date())
        )
        let principal = InterestCalculator.totalPrincipal(contributions)
        let dateStr = Self.formatDate(Date())
        let ids = Self.payoutIds(depositId: deposit.id)
        // Writes through `createOnce`: a row a previous attempt already
        // wrote under its payout id is returned instead of written again.
        let transactionRepo = PayoutWriter(base: self.transactionRepo)

        // Step 1. Interest income transaction on the deposit account
        // (only if accrued > 0). Using income type without category —
        // the category picker has no "interest" option in MVP.
        if accrued > 0 {
            let accruedDecimal = Decimal(accrued) / 100
            let interest = try await transactionRepo.create(CreateTransactionInput(
                user_id: userId,
                account_id: depositAccount.id,
                amount: accruedDecimal,
                amount_native: accruedDecimal,
                currency: depositAccount.currency.uppercased(),
                type: TransactionType.income.rawValue,
                date: dateStr,
                description: String(localized: "deposit.transaction.interestEarned"),
                category_id: nil,
                merchant_name: depositAccount.name
            ).withClientId(ids.interest))
            // A retry returns what the first attempt booked — the transfer
            // below must move exactly that.
            accrued = interest.amountNative
        }
        let total = principal + accrued

        // Step 2. Transfer pair: deposit → returnTo for principal+accrued.
        // Cross-currency: each leg is written in its OWN account currency
        // (expense leg in deposit's, income leg in returnTo's), FX-
        // converting through today's rates. Without the conversion the
        // return would under-credit (USD-valued total written as 1000 RUB
        // on a RUB return account instead of ~92 500 ₽).
        if total > 0 {
            let groupId = ids.transferGroup
            let isSameCurrency = depositAccount.currency.uppercased() == returnTo.currency.uppercased()
            let totalDecimal = Decimal(total) / 100

            _ = try await transactionRepo.create(CreateTransactionInput(
                user_id: userId,
                account_id: depositAccount.id,
                amount: totalDecimal,
                amount_native: totalDecimal,
                currency: depositAccount.currency.uppercased(),
                type: TransactionType.expense.rawValue,
                date: dateStr,
                description: String(localized: "deposit.transfer.return"),
                category_id: nil,
                merchant_name: depositAccount.name,
                transfer_group_id: groupId
            ).withClientId(ids.returnOut))

            let destAmount: Decimal = {
                guard !isSameCurrency else { return totalDecimal }
                let fxRates = dataStore.currencyContext.fxRates
                let converted = NetWorthCalculator.convert(
                    amount: total,
                    from: depositAccount.currency,
                    to: returnTo.currency,
                    rates: fxRates
                )
                return Decimal(converted) / 100
            }()
            _ = try await transactionRepo.create(CreateTransactionInput(
                user_id: userId,
                account_id: returnTo.id,
                amount: destAmount,
                amount_native: destAmount,
                currency: returnTo.currency.uppercased(),
                type: TransactionType.income.rawValue,
                date: dateStr,
                description: String(localized: "deposit.transfer.return"),
                category_id: nil,
                merchant_name: depositAccount.name,
                transfer_group_id: groupId
            ).withClientId(ids.returnIn))
        }
    }

    // MARK: - Delete

    /// Deletes a deposit by deleting the tied account (which cascades).
    /// Transactions stay for audit purposes — user can clean them up
    /// manually if desired.
    func delete(_ deposit: Deposit, dataStore: DataStore) async {
        do {
            try await accountRepo.delete(id: deposit.accountId)
            deposits.removeAll { $0.id == deposit.id }
            contributionsByDeposit.removeValue(forKey: deposit.id)
            await dataStore.loadAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Live computed properties

    /// Live accrued interest (not stored). Call this from UI with `Date()`
    /// as `asOf` to get "now" or with `endDate` to project maturity.
    /// Never past `Deposit.accrualCutoff` — an overdue deposit stops
    /// growing on its end date (V1).
    func liveAccruedInterest(for deposit: Deposit, asOf: Date = Date()) -> Int64 {
        let contributions = contributionsByDeposit[deposit.id] ?? []
        return InterestCalculator.accrueInterest(
            contributions: contributions,
            rate: deposit.interestRate,
            frequency: deposit.compoundFrequency,
            asOf: deposit.accrualCutoff(now: asOf)
        )
    }

    /// Principal + live accrued, in deposit kopecks.
    func liveTotalValue(for deposit: Deposit, asOf: Date = Date()) -> Int64 {
        let contributions = contributionsByDeposit[deposit.id] ?? []
        return InterestCalculator.totalPrincipal(contributions)
            + liveAccruedInterest(for: deposit, asOf: asOf)
    }

    /// Projected total value at the deposit's `endDate`. `nil` if no end date.
    func projectedMaturityValue(for deposit: Deposit) -> Int64? {
        guard let endStr = deposit.endDate, let end = Self.parseDate(endStr) else { return nil }
        let contributions = contributionsByDeposit[deposit.id] ?? []
        return InterestCalculator.projectedMaturityValue(
            contributions: contributions,
            rate: deposit.interestRate,
            frequency: deposit.compoundFrequency,
            maturityDate: end
        )
    }

    // MARK: - Date helpers

    // Pure helpers — no access to instance state. Marked `nonisolated` so
    // they can be passed as `.map(Self.formatDate)` from a nonisolated
    // closure context. Without this marker Swift 6 Release treats them
    // as MainActor-isolated (because the enclosing class is `@MainActor`)
    // and the closure context becomes invalid (Codemagic build failure,
    // 2026-04-19).
    //
    // Day strings (start_date, end_date, contributed_at, the transfer legs'
    // `date`) are the user's LOCAL calendar day — the same convention as
    // every other `yyyy-MM-dd` in the app (see AppDateFormatters). They were
    // formatted in UTC: a top-up at 05:00 on 1 December in UTC+7 was written
    // as 30 November and landed in November's reports and budgets (D3).
    // `InterestCalculator.defaultCalendar` uses the same zone, so day counts
    // and maturity checks agree with these strings.
    nonisolated static func formatDate(_ date: Date) -> String {
        AppDateFormatters.isoDate.string(from: date)
    }

    /// `formatDate` as seen from another time zone (tests).
    nonisolated static func formatDate(_ date: Date, in timeZone: TimeZone) -> String {
        AppDateFormatters.localDate(in: timeZone).string(from: date)
    }

    /// Start of that local day.
    nonisolated static func parseDate(_ str: String) -> Date? {
        AppDateFormatters.isoDate.date(from: String(str.prefix(10)))
    }

    /// An instant (`closed_at` is timestamptz) — UTC with offset.
    nonisolated static func formatDateTime(_ date: Date) -> String {
        AppDateFormatters.utcTimestamp.string(from: date)
    }
}
