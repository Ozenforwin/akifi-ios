import Foundation

enum SavingsStatus {
    case onTrack, behind, critical, completed, noDeadline

    var label: String {
        switch self {
        case .onTrack: return String(localized: "savings.status.onTrack")
        case .behind: return String(localized: "savings.status.behind")
        case .critical: return String(localized: "savings.status.critical")
        case .completed: return String(localized: "savings.status.completed")
        case .noDeadline: return String(localized: "savings.status.noDeadline")
        }
    }

    var color: String {
        switch self {
        case .onTrack: return "#22C55E"
        case .behind: return "#F59E0B"
        case .critical: return "#EF4444"
        case .completed: return "#22C55E"
        case .noDeadline: return "#6B7280"
        }
    }
}

@Observable @MainActor
final class SavingsViewModel {
    var goals: [SavingsGoal] = []
    var contributions: [String: [SavingsContribution]] = [:]
    var isLoading = false
    var error: String?
    var showForm = false

    private let repo = SavingsGoalRepository()

    /// Routes the linked transfer through the offline-aware write path
    /// (queue on no network, banner on failure). Set by the owning view;
    /// without it the transfer goes straight to the repository.
    @ObservationIgnored var dataStore: DataStore?

    /// "yyyy-MM-dd" in the device time zone, pinned to POSIX + Gregorian so
    /// a Buddhist/Japanese calendar region can't write year 2569 (D1).
    private var isoDateFormatter: DateFormatter { AppDateFormatters.isoDate }

    var activeGoals: [SavingsGoal] {
        goals.filter { $0.status == .active }
    }

    var completedGoals: [SavingsGoal] {
        goals.filter { $0.status == .completed }
    }

    func load() async {
        isLoading = true
        error = nil
        do {
            goals = try await repo.fetchAll()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func loadContributions(for goalId: String) async {
        do {
            contributions[goalId] = try await repo.fetchContributions(goalId: goalId)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func createGoal(name: String, icon: String, color: String, targetAmount: Int64, deadline: String?, accountId: String?) async {
        do {
            let userId = try await repo.currentUserId()
            let input = CreateSavingsGoalInput(
                user_id: userId,
                name: name,
                icon: icon,
                color: color,
                target_amount: targetAmount,
                deadline: deadline,
                account_id: accountId,
                reminder_enabled: false,
                priority: goals.count
            )
            let goal = try await repo.create(input)
            goals.insert(goal, at: 0)
            AnalyticsService.logCreateGoal()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Records a contribution / withdrawal and the account movement it
    /// stands for (M2, see `accountLegs`).
    ///
    /// - `linkedAccount`: the goal's account — where the goal's money lives.
    /// - `counterAccount`: where a contribution comes FROM / a withdrawal
    ///   goes TO; nil = none (see `accountLegs`).
    /// - `amount`: kopecks in the linked account's currency.
    func addContribution(
        goalId: String,
        amount: Int64,
        type: ContributionType,
        note: String?,
        linkedAccount: Account?,
        counterAccount: Account?,
        currencyManager: CurrencyManager?
    ) async {
        do {
            // Everything that can fail without a write comes first: a missing
            // rate for a cross-currency counter-account saves nothing.
            let rates: [String: Double]
            if let linkedAccount, let counterAccount {
                rates = await currencyManager?.ratesForWrite([linkedAccount.currency, counterAccount.currency]) ?? [:]
            } else {
                rates = [:]
            }
            let legs = try Self.accountLegs(
                type: type, amount: amount,
                linked: linkedAccount, counter: counterAccount, rates: rates
            )

            let userId = try await repo.currentUserId()
            let input = CreateContributionInput(
                user_id: userId,
                goal_id: goalId,
                amount: amount,
                type: type.rawValue,
                note: note
            )
            let contribution = try await repo.addContribution(input)
            AnalyticsService.logContribution(type: type.rawValue, amount: Double(amount) / 100)

            let goal = goals.first { $0.id == goalId }
            let desc = "\(goal?.name ?? String(localized: "home.savings")): \(type == .withdrawal ? String(localized: "contribution.withdrawal") : String(localized: "contribution.deposit"))\(note != nil ? " — \(note!)" : "")"
            let dateStr = isoDateFormatter.string(from: Date())
            let groupId = legs.count > 1 ? UUID().uuidString : nil
            var written: [Transaction] = []
            do {
                for leg in legs {
                    let txInput = CreateTransactionInput(
                        user_id: userId,
                        account_id: leg.accountId,
                        amount: leg.amountNative,
                        amount_native: leg.amountNative,
                        currency: leg.currency,
                        foreign_amount: leg.foreignAmount,
                        foreign_currency: leg.foreignCurrency,
                        fx_rate: leg.fxRate,
                        type: leg.type.rawValue,
                        date: dateStr,
                        description: desc,
                        category_id: nil,
                        merchant_name: nil,
                        transfer_group_id: groupId
                    )
                    // Through DataStore when available: no network / no
                    // answer → queued like any offline entry, and the account
                    // balance moves locally right away.
                    if let dataStore {
                        written.append(try await dataStore.addTransaction(txInput))
                    } else {
                        written.append(try await TransactionRepository().create(txInput.withClientId()))
                    }
                }
            } catch {
                // The account side was rejected: undo what did land and the
                // goal side, so the goal doesn't show money the accounts
                // never moved (Y10) and no half transfer stays behind.
                for tx in written {
                    _ = await dataStore?.deleteTransaction(tx)
                }
                try? await repo.deleteContribution(id: contribution.id)
                await load()
                dataStore?.reportIssue(.mutation, message: error.localizedDescription)
                throw error
            }

            // Update local state
            var existing = contributions[goalId] ?? []
            existing.insert(contribution, at: 0)
            contributions[goalId] = existing

            // Reload goal from DB (trigger auto-updates current_amount)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Account movement of a contribution (M2)

    /// One transaction row a contribution writes.
    struct AccountLeg: Equatable, Sendable {
        let accountId: String
        let type: TransactionType
        /// Main units of the leg account's currency, signed as stored.
        let amountNative: Decimal
        let currency: String
        let foreignAmount: Decimal?
        let foreignCurrency: String?
        let fxRate: Decimal?
    }

    /// What a goal contribution does to real accounts. The goal's money
    /// lives on its linked account L; `counter` is the other side.
    ///
    /// - No linked account → nothing (a goal not tied to an account).
    /// - Contribution from S ≠ L → a two-leg transfer S → L (expense leg on
    ///   S, income leg on L, one `transfer_group_id`): L up, S down, no
    ///   income or spending in analytics.
    /// - Contribution with no source → nothing: the money is already on L,
    ///   the goal just earmarks it. It used to write a positive legacy
    ///   `.transfer` on L — money out of nowhere.
    /// - Withdrawal to D ≠ L → a two-leg transfer L → D.
    /// - Withdrawal with no destination → one legacy `.transfer` row on L with
    ///   a NEGATIVE amount: L goes down, cashflow untouched
    ///   (`NativeBalance.signedAmount`). The positive row it used to write
    ///   raised L by the amount taken out.
    ///
    /// `amount` is kopecks of L's currency; a counter-account in another
    /// currency gets its leg converted with `rates` (write rates — throws
    /// `MissingFXRateError` rather than guess).
    static func accountLegs(
        type: ContributionType,
        amount: Int64,
        linked: Account?,
        counter: Account?,
        rates: [String: Double]
    ) throws -> [AccountLeg] {
        guard let linked, amount > 0 else { return [] }
        let units = Decimal(amount) / 100
        let linkedCode = linked.currencyCode
        let counter = counter.flatMap { $0.id == linked.id ? nil : $0 }

        func leg(on account: Account, type: TransactionType) throws -> AccountLeg {
            let fields = try TransferFormView.legFields(
                amountValue: units, entryCurrency: linkedCode, account: account, rates: rates
            )
            return AccountLeg(
                accountId: account.id, type: type, amountNative: fields.amountInAccount,
                currency: fields.currencyLabel, foreignAmount: fields.foreignAmount,
                foreignCurrency: fields.foreignCurrency, fxRate: fields.fxRate
            )
        }

        switch (type, counter) {
        case (.contribution, nil), (.interest, _):
            // Interest is goal bookkeeping; the bank's own payout reaches the
            // account through its statement, not through this row.
            return []
        case (.contribution, let source?):
            return [try leg(on: source, type: .expense), try leg(on: linked, type: .income)]
        case (.withdrawal, nil):
            return [AccountLeg(
                accountId: linked.id, type: .transfer, amountNative: -units,
                currency: linkedCode.code, foreignAmount: nil, foreignCurrency: nil, fxRate: nil
            )]
        case (.withdrawal, let destination?):
            return [try leg(on: linked, type: .expense), try leg(on: destination, type: .income)]
        }
    }

    /// Savings status based on pace
    func savingsStatus(for goal: SavingsGoal) -> SavingsStatus {
        guard goal.targetAmount > goal.currentAmount else { return .completed }
        guard let days = daysRemaining(for: goal), days > 0 else {
            if goal.deadline != nil { return .critical }
            return .noDeadline
        }
        let remaining = goal.targetAmount - goal.currentAmount
        let dailyNeeded = Double(remaining) / Double(days)

        // Check if on track based on contributions
        let contribs = contributions[goal.id] ?? []
        let goalAge = Self.goalAgeDays(createdAt: goal.createdAt)
        let avgDaily = contribs.filter { $0.type == .contribution }.reduce(Int64(0)) { $0 + $1.amount } // allowlisted-amount: DepositContribution.amount is in the goal's own currency
        let avgDailyRate = Double(avgDaily) / Double(goalAge)

        if avgDailyRate >= dailyNeeded * 0.8 { return .onTrack }
        if avgDailyRate >= dailyNeeded * 0.4 { return .behind }
        return .critical
    }

    /// Whole days since the goal was created, at least 1 (D10). `created_at`
    /// is a full timestamp (`2026-05-01T12:34:56.789+00:00`); parsing it
    /// with "yyyy-MM-dd" returned nil, the age fell back to "now" → 1 day,
    /// and every goal with any contribution looked on track.
    static func goalAgeDays(createdAt: String?, now: Date = Date(), calendar: Calendar = .current) -> Int {
        guard let createdAt, let created = parseTimestamp(createdAt) else { return 1 }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: created),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        return max(1, days)
    }

    /// Postgres timestamptz text → Date: with or without fractional
    /// seconds, or a bare "yyyy-MM-dd" (UTC midnight).
    static func parseTimestamp(_ raw: String) -> Date? {
        AppDateFormatters.parseTimestamp(raw)
            ?? AppDateFormatters.utcDate.date(from: String(raw.prefix(10)))
    }

    func deleteGoal(_ goal: SavingsGoal) async {
        do {
            try await repo.delete(id: goal.id)
            goals.removeAll { $0.id == goal.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func progress(for goal: SavingsGoal) -> Double {
        guard goal.targetAmount > 0 else { return 0 }
        return min(Double(goal.currentAmount) / Double(goal.targetAmount), 1.0)
    }

    func daysRemaining(for goal: SavingsGoal) -> Int? {
        guard let deadline = goal.deadline else { return nil }
        guard let date = isoDateFormatter.date(from: deadline) else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: date).day
    }
}
