import Foundation

/// The four «Долги» actions (contract §A5). Each is an ordinary manual
/// transfer between a real (money) account and the debt account.
enum DebtAction: String, CaseIterable, Identifiable, Sendable {
    /// «Дал в долг» — real → debt, balance + amount.
    case lend
    /// «Мне вернули» — debt → real, balance − amount (towards 0).
    case gotRepaid
    /// «Взял в долг» — debt → real, balance − amount.
    case borrow
    /// «Я вернул» — real → debt, balance + amount (towards 0).
    case repaid

    var id: String { rawValue }

    /// true: the money goes from the real account into the debt account
    /// (the debt leg is the income leg).
    var movesIntoDebt: Bool {
        switch self {
        case .lend, .repaid: return true
        case .gotRepaid, .borrow: return false
        }
    }

    /// Sign of the change of the debt balance.
    var balanceSign: Int64 { movesIntoDebt ? 1 : -1 }

    /// Repayments close an existing balance; the other two open/grow one.
    var isRepayment: Bool { self == .gotRepaid || self == .repaid }

    var title: String {
        switch self {
        case .lend: return String(localized: "debts.action.lend")
        case .gotRepaid: return String(localized: "debts.action.gotRepaid")
        case .borrow: return String(localized: "debts.action.borrow")
        case .repaid: return String(localized: "debts.action.repaid")
        }
    }

    var systemImage: String {
        switch self {
        case .lend: return "arrow.up.right"
        case .gotRepaid: return "arrow.down.left"
        case .borrow: return "arrow.down.left"
        case .repaid: return "arrow.up.right"
        }
    }

    /// Prefilled amount (minor units): a repayment defaults to `|balance|`
    /// when the balance points its way, otherwise nothing.
    func defaultAmount(balance: Int64) -> Int64? {
        switch self {
        case .gotRepaid: return balance > 0 ? balance : nil
        case .repaid: return balance < 0 ? -balance : nil
        case .lend, .borrow: return nil
        }
    }

    /// The balance after this action of `amount` minor units.
    func balance(after amount: Int64, from balance: Int64) -> Int64 {
        balance + balanceSign * amount
    }

    /// A repayment larger than what is owed flips the sign of the debt
    /// (contract §A5: "More flips the sign: confirm with the user first").
    func flipsSign(amount: Int64, balance: Int64) -> Bool {
        guard isRepayment, amount > 0 else { return false }
        let after = self.balance(after: amount, from: balance)
        return (balance > 0 && after < 0) || (balance < 0 && after > 0) || (balance == 0 && after != 0)
    }

    /// A repayment that lands exactly on zero → suggest «Закрыть долг».
    func settles(amount: Int64, balance: Int64) -> Bool {
        balance != 0 && self.balance(after: amount, from: balance) == 0
    }
}

enum DebtTransferError: LocalizedError, Equatable {
    case notADebtAccount
    case notAMoneyAccount
    case invalidAmount

    var errorDescription: String? {
        switch self {
        case .notADebtAccount, .notAMoneyAccount: return String(localized: "debts.error.account")
        case .invalidAmount: return String(localized: "transaction.invalidAmount")
        }
    }
}

/// Builds the two legs of a debt movement. Pure: the caller fetches real
/// FX quotes (`CurrencyManager.ratesForWrite`) and writes the legs through
/// `DataStore.addTransaction` — the same path as a manual transfer, so the
/// offline queue, client ids and placeholders apply (contract §A5).
enum DebtTransferBuilder {

    struct Legs: Sendable {
        let groupId: String
        /// Written first (like `TransferFormView`).
        let expense: CreateTransactionInput
        let income: CreateTransactionInput
    }

    /// - `amount`: what the user typed, in `entryCurrency` (main units).
    /// - Each leg is in ITS account's currency (ADR-001): the converted leg
    ///   keeps the entry in `foreign_*` — `TransferFormView.legFields`, the
    ///   manual-transfer rule; a missing quote throws, never a 1:1 leg.
    /// - `transfer_group_id` shared, `auto_transfer_group_id`,
    ///   `category_id` and `personal_debt_user_id` null, same author and
    ///   date on both legs.
    static func legs(
        action: DebtAction,
        amount: Decimal,
        entryCurrency: CurrencyCode,
        debtAccount: Account,
        realAccount: Account,
        rates: [String: Double],
        userId: String,
        date: String,
        counterpartyName: String,
        comment: String?,
        groupId: String = UUID().uuidString.lowercased()
    ) throws -> Legs {
        guard debtAccount.isDebtAccount else { throw DebtTransferError.notADebtAccount }
        guard realAccount.isMoneyAccount, realAccount.id != debtAccount.id else { throw DebtTransferError.notAMoneyAccount }
        guard amount > 0 else { throw DebtTransferError.invalidAmount }

        let debtLeg = try TransferFormView.legFields(
            amountValue: amount, entryCurrency: entryCurrency, account: debtAccount, rates: rates
        )
        let realLeg = try TransferFormView.legFields(
            amountValue: amount, entryCurrency: entryCurrency, account: realAccount, rates: rates
        )
        let description = descriptionText(counterpartyName: counterpartyName, comment: comment)

        func input(_ leg: TransferFormView.LegFields, account: Account, type: TransactionType) -> CreateTransactionInput {
            CreateTransactionInput(
                user_id: userId,
                account_id: account.id,
                amount: leg.amountInAccount,
                amount_native: leg.amountInAccount,
                currency: leg.currencyLabel,
                foreign_amount: leg.foreignAmount,
                foreign_currency: leg.foreignCurrency,
                fx_rate: leg.fxRate,
                type: type.rawValue,
                date: date,
                description: description,
                category_id: nil,
                merchant_name: counterpartyName,
                transfer_group_id: groupId
            )
        }

        if action.movesIntoDebt {
            return Legs(
                groupId: groupId,
                expense: input(realLeg, account: realAccount, type: .expense),
                income: input(debtLeg, account: debtAccount, type: .income)
            )
        }
        return Legs(
            groupId: groupId,
            expense: input(debtLeg, account: debtAccount, type: .expense),
            income: input(realLeg, account: realAccount, type: .income)
        )
    }

    /// «Долг: Маша» (+ « · comment»).
    static func descriptionText(counterpartyName: String, comment: String?) -> String {
        let base = String(localized: "debts.transfer.description \(counterpartyName)")
        guard let comment = comment?.trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty else { return base }
        return "\(base) · \(comment)"
    }

    /// «Погасить» (contract §B5): a manual transfer from one of the user's
    /// own money accounts into the shared account; the INCOME leg on the
    /// shared account carries `personal_debt_user_id = me`, the expense leg
    /// on the card carries nothing.
    static func personalRepaymentLegs(
        amount: Decimal,
        entryCurrency: CurrencyCode,
        sharedAccount: Account,
        fromAccount: Account,
        rates: [String: Double],
        userId: String,
        date: String,
        groupId: String = UUID().uuidString.lowercased()
    ) throws -> Legs {
        guard fromAccount.isMoneyAccount, sharedAccount.isMoneyAccount,
              fromAccount.id != sharedAccount.id else { throw DebtTransferError.notAMoneyAccount }
        guard amount > 0 else { throw DebtTransferError.invalidAmount }
        let outLeg = try TransferFormView.legFields(
            amountValue: amount, entryCurrency: entryCurrency, account: fromAccount, rates: rates
        )
        let inLeg = try TransferFormView.legFields(
            amountValue: amount, entryCurrency: entryCurrency, account: sharedAccount, rates: rates
        )
        let description = String(localized: "personalDebt.repay.description \(sharedAccount.name)")
        return Legs(
            groupId: groupId,
            expense: CreateTransactionInput(
                user_id: userId, account_id: fromAccount.id,
                amount: outLeg.amountInAccount, amount_native: outLeg.amountInAccount,
                currency: outLeg.currencyLabel,
                foreign_amount: outLeg.foreignAmount, foreign_currency: outLeg.foreignCurrency, fx_rate: outLeg.fxRate,
                type: TransactionType.expense.rawValue, date: date, description: description,
                category_id: nil, merchant_name: nil, transfer_group_id: groupId
            ),
            income: CreateTransactionInput(
                user_id: userId, account_id: sharedAccount.id,
                amount: inLeg.amountInAccount, amount_native: inLeg.amountInAccount,
                currency: inLeg.currencyLabel,
                foreign_amount: inLeg.foreignAmount, foreign_currency: inLeg.foreignCurrency, fx_rate: inLeg.fxRate,
                type: TransactionType.income.rawValue, date: date, description: description,
                category_id: nil, merchant_name: nil, transfer_group_id: groupId,
                personal_debt_user_id: userId
            )
        )
    }

    /// The debt account a transfer leg belongs to, if `leg` is one side of a
    /// debt movement (either leg). nil for every other row.
    static func debtAccount(of leg: Transaction, accounts: (String?) -> Account?, transactions: [Transaction]) -> Account? {
        guard let group = leg.manualTransferGroupId else { return nil }
        if let own = accounts(leg.accountId), own.isDebtAccount { return own }
        for peer in transactions where peer.id != leg.id && peer.isManualTransferLeg(ofGroup: group) {
            if let acc = accounts(peer.accountId), acc.isDebtAccount { return acc }
        }
        return nil
    }
}
