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

        // Fetch contributions for every deposit in parallel.
        await withTaskGroup(of: (String, [DepositContribution]?).self) { group in
            for d in deposits {
                group.addTask { [contributionRepo] in
                    let contributions = try? await contributionRepo.fetchForDeposit(d.id)
                    return (d.id, contributions)
                }
            }
            for await (depositId, list) in group {
                if let list { contributionsByDeposit[depositId] = list }
            }
        }

        // Auto-maturity pass. Iterate over a snapshot; `matureDeposit`
        // mutates `deposits` in place.
        let today = InterestCalculator.defaultCalendar.startOfDay(for: Date())
        let snapshot = deposits
        for deposit in snapshot where deposit.status == .active {
            guard let endDateStr = deposit.endDate,
                  let endDate = Self.parseDate(endDateStr) else {
                continue
            }
            if endDate <= today {
                await matureDeposit(deposit, dataStore: dataStore)
            }
        }
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
        returnToAccountId: String?,
        dataStore: DataStore,
        currencyManager: CurrencyManager
    ) async throws {
        // M1: the source leg, converted deposit → source DIRECTLY with real
        // quotes — before anything is written, so a missing rate saves
        // nothing (no orphan deposit account).
        let rates = await currencyManager.ratesForWrite([currency.code, sourceAccount.currency])
        let leg = try Self.convertLeg(
            kopecks: initialAmount, from: currency.code, to: sourceAccount.currency, rates: rates
        )
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
        let isSameCurrency = !leg.isCrossCurrency
        let sourceAmountKopecks = leg.kopecks
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
            fx_rate: isSameCurrency ? nil : leg.depositPerSource,
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
        dataStore: DataStore,
        currencyManager: CurrencyManager
    ) async throws {
        // M1: deposit → source directly, real quotes only, before any write.
        let rates = await currencyManager.ratesForWrite([depositAccount.currency, sourceAccount.currency])
        let leg = try Self.convertLeg(
            kopecks: amountInDeposit, from: depositAccount.currency, to: sourceAccount.currency, rates: rates
        )
        let userId = try await SupabaseManager.shared.currentUserId()
        let groupId = UUID().uuidString
        let dateStr = Self.formatDate(Date())

        let isSameCurrency = !leg.isCrossCurrency
        let sourceAmountKopecks = leg.kopecks
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
            fx_rate: isSameCurrency ? nil : leg.depositPerSource,
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
        } catch {
            AppLogger.data.warning("auto-mature failed for \(deposit.id): \(error.localizedDescription)")
        }
    }

    private func closeOrMature(
        _ deposit: Deposit,
        depositAccount: Account,
        returnTo: Account,
        newStatus: DepositStatus,
        dataStore: DataStore
    ) async throws {
        let userId = try await SupabaseManager.shared.currentUserId()
        let contributions = contributionsByDeposit[deposit.id] ?? []
        let accrued = InterestCalculator.accrueInterest(
            contributions: contributions,
            rate: deposit.interestRate,
            frequency: deposit.compoundFrequency,
            asOf: Date()
        )
        let principal = InterestCalculator.totalPrincipal(contributions)
        let total = principal + accrued
        let dateStr = Self.formatDate(Date())

        // M1: the return leg in returnTo's currency, converted deposit →
        // returnTo directly with real quotes (never the base currency, never
        // 1:1 on a missing rate) — before the first write, so a missing rate
        // changes nothing and auto-maturity simply retries on the next load.
        let returnLeg: ConvertedLeg
        if total > 0 {
            let rates = await dataStore.currencyManager?.ratesForWrite([depositAccount.currency, returnTo.currency]) ?? [:]
            returnLeg = try Self.convertLeg(
                kopecks: total, from: depositAccount.currency, to: returnTo.currency, rates: rates
            )
        } else {
            returnLeg = ConvertedLeg(kopecks: 0, isCrossCurrency: false, depositPerSource: nil)
        }

        // Step 1. Interest income transaction on the deposit account
        // (only if accrued > 0). Using income type without category —
        // the category picker has no "interest" option in MVP.
        if accrued > 0 {
            let accruedDecimal = Decimal(accrued) / 100
            _ = try await transactionRepo.create(CreateTransactionInput(
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
            ))
        }

        // Step 2. Transfer pair: deposit → returnTo for principal+accrued.
        // Cross-currency: each leg is written in its OWN account currency
        // (expense leg in deposit's, income leg in returnTo's), FX-
        // converting through today's rates. Without the conversion the
        // return would under-credit (USD-valued total written as 1000 RUB
        // on a RUB return account instead of ~92 500 ₽).
        if total > 0 {
            let groupId = UUID().uuidString
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
            ))

            let destAmount = Decimal(returnLeg.kopecks) / 100
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
            ))
        }

        // Step 3. Update status.
        let closedAtStr = Self.formatDateTime(Date())
        try await depositRepo.update(id: deposit.id, UpdateDepositInput(
            notes: nil,
            return_to_account_id: returnTo.id,
            early_close_penalty_rate: nil,
            status: newStatus.rawValue,
            closed_at: closedAtStr,
            end_date: nil
        ))

        if let idx = deposits.firstIndex(where: { $0.id == deposit.id }) {
            var updated = deposits[idx]
            updated.status = newStatus
            updated.closedAt = closedAtStr
            deposits[idx] = updated
        }

        await dataStore.loadAll()
    }

    // MARK: - Cross-currency legs (M1)

    /// One transfer leg moved from `from`-currency kopecks into the `to`
    /// account's currency.
    struct ConvertedLeg: Equatable, Sendable {
        /// Kopecks (minor units ×100, the app-wide convention) of `to`.
        let kopecks: Int64
        let isCrossCurrency: Bool
        /// Units of `from` per unit of `to` — the `deposit_contributions.fx_rate`
        /// convention (deposit per source). Nil when same-currency or zero.
        let depositPerSource: Decimal?
    }

    /// Converts `kopecks` of `from` straight into `to` with USD-pivoted
    /// write rates. The old path read the amount as BASE currency
    /// (`convertToAccountCurrency`): a $1 000 deposit from a rouble card with
    /// a rouble base debited 1 000 ₽, and a missing rate went through 1:1.
    /// Throws `MissingFXRateError` instead.
    nonisolated static func convertLeg(
        kopecks: Int64,
        from: String,
        to: String,
        rates: [String: Double]
    ) throws -> ConvertedLeg {
        let src = from.uppercased()
        let dst = to.uppercased()
        guard src != dst else {
            return ConvertedLeg(kopecks: kopecks, isCrossCurrency: false, depositPerSource: nil)
        }
        let units = Decimal(kopecks) / 100
        let converted = try TransactionMath.convertForStorage(units, from: src, to: dst, rates: rates)
        var scaled = converted * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        let out = Int64(truncating: rounded as NSDecimalNumber)
        return ConvertedLeg(
            kopecks: out,
            isCrossCurrency: true,
            depositPerSource: converted > 0 ? units / converted : nil
        )
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
    func liveAccruedInterest(for deposit: Deposit, asOf: Date = Date()) -> Int64 {
        let contributions = contributionsByDeposit[deposit.id] ?? []
        return InterestCalculator.accrueInterest(
            contributions: contributions,
            rate: deposit.interestRate,
            frequency: deposit.compoundFrequency,
            asOf: asOf
        )
    }

    /// Principal + live accrued, in deposit kopecks.
    func liveTotalValue(for deposit: Deposit, asOf: Date = Date()) -> Int64 {
        let contributions = contributionsByDeposit[deposit.id] ?? []
        return InterestCalculator.totalPrincipal(contributions)
            + InterestCalculator.accrueInterest(
                contributions: contributions,
                rate: deposit.interestRate,
                frequency: deposit.compoundFrequency,
                asOf: asOf
            )
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
