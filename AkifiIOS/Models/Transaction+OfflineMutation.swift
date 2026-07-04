import Foundation

/// Errors surfaced by DataStore's offline mutation paths.
enum OfflineMutationError: LocalizedError {
    case transactionNotFound
    /// Editing a payment-source expense that only exists in the offline
    /// queue: its triplet is created server-side by the RPC with fresh ids,
    /// so a queued update could never target the right rows after sync.
    case pendingAutoTransferEdit

    var errorDescription: String? {
        switch self {
        case .transactionNotFound:
            return String(localized: "offline.transactionNotFound")
        case .pendingAutoTransferEdit:
            return String(localized: "offline.pendingAutoTransferEdit")
        }
    }
}

extension CreateTransactionInput {
    /// Mirrors `TransactionRepository.create`'s routing decision: expenses
    /// funded from a different account go through the
    /// `create_expense_with_auto_transfer` RPC.
    var routesToAutoTransferRPC: Bool {
        type == TransactionType.expense.rawValue
            && payment_source_account_id != nil
            && payment_source_account_id != account_id
            && transfer_group_id == nil
    }
}

// MARK: - Local placeholder construction
//
// Placeholders are full-fidelity local rows built from the queued input so
// balances and analytics stay correct while offline. They carry
// `status == "pending"` (clock icon in the journal) and are replaced by the
// server rows on the first successful sync — for plain inserts the client
// id IS the server id, so replacement is seamless.

extension Transaction {
    static func placeholder(for input: CreateTransactionInput, nowISO: String) -> Transaction {
        Transaction(
            id: input.id ?? UUID().uuidString.lowercased(),
            userId: input.user_id,
            accountId: input.account_id,
            amount: input.amount_native.kopecks,
            amountNative: input.amount_native.kopecks,
            currency: input.currency,
            foreignAmount: input.foreign_amount,
            foreignCurrency: input.foreign_currency,
            fxRate: input.fx_rate,
            description: input.description,
            categoryId: input.category_id,
            type: TransactionType(rawValue: input.type) ?? .expense,
            date: String(input.date.prefix(10)),
            rawDateTime: input.date,
            merchantName: input.merchant_name,
            merchantFuzzy: nil,
            transferGroupId: input.transfer_group_id,
            status: "pending",
            createdAt: nowISO,
            updatedAt: nil
        )
    }

    /// Local mirror of the `create_expense_with_auto_transfer` RPC: the
    /// expense on the target account plus transfer-out (source) and
    /// transfer-in (target) legs. Ids are derived from the expense's client
    /// id so re-applying the overlay keeps SwiftUI identity stable. The RPC
    /// generates its own ids server-side — these rows are replaced wholesale
    /// on the first post-sync fetch (which is why editing a pending triplet
    /// is blocked).
    static func placeholderTriplet(for input: CreateTransactionInput, nowISO: String) -> [Transaction] {
        let expenseId = input.id ?? UUID().uuidString.lowercased()
        let groupId = "\(expenseId)-atg"
        // Same fallback chain as the RPC (source_* → target values), and the
        // same hardcoded Russian leg description the server writes.
        let sourceAmount = input.source_amount ?? input.amount
        let sourceCurrency = input.source_currency ?? input.currency
        let transferDesc = "Авто-перевод: " + ((input.description?.isEmpty == false ? input.description : nil) ?? "расход")

        let expense = Transaction(
            id: expenseId,
            userId: input.user_id,
            accountId: input.account_id,
            amount: input.amount_native.kopecks,
            amountNative: input.amount_native.kopecks,
            currency: input.currency,
            foreignAmount: input.foreign_amount,
            foreignCurrency: input.foreign_currency,
            fxRate: input.fx_rate,
            description: input.description,
            categoryId: input.category_id,
            type: .expense,
            date: String(input.date.prefix(10)),
            rawDateTime: input.date,
            merchantName: input.merchant_name,
            merchantFuzzy: nil,
            transferGroupId: nil,
            paymentSourceAccountId: input.payment_source_account_id,
            autoTransferGroupId: groupId,
            status: "pending",
            createdAt: nowISO,
            updatedAt: nil
        )

        let transferOut = Transaction(
            id: "\(expenseId)-out",
            userId: input.user_id,
            accountId: input.payment_source_account_id,
            amount: sourceAmount.kopecks,
            amountNative: sourceAmount.kopecks,
            currency: sourceCurrency,
            description: transferDesc,
            categoryId: nil,
            type: .expense,
            date: String(input.date.prefix(10)),
            rawDateTime: input.date,
            merchantName: nil,
            merchantFuzzy: nil,
            transferGroupId: groupId,
            autoTransferGroupId: groupId,
            status: "pending",
            createdAt: nowISO,
            updatedAt: nil
        )

        let transferIn = Transaction(
            id: "\(expenseId)-in",
            userId: input.user_id,
            accountId: input.account_id,
            amount: input.amount_native.kopecks,
            amountNative: input.amount_native.kopecks,
            currency: input.currency,
            description: transferDesc,
            categoryId: nil,
            type: .income,
            date: String(input.date.prefix(10)),
            rawDateTime: input.date,
            merchantName: nil,
            merchantFuzzy: nil,
            transferGroupId: groupId,
            autoTransferGroupId: groupId,
            status: "pending",
            createdAt: nowISO,
            updatedAt: nil
        )

        return [expense, transferOut, transferIn]
    }

    /// Applies a queued `UpdateTransactionInput` onto the local row,
    /// mirroring the server's patch semantics: non-nil fields overwrite,
    /// except when `replaceCurrencyFields` is set — then the whole currency
    /// block is taken verbatim (nil clears, matching the JSON-null UPDATE).
    /// The result is marked `pending` until the queue drains.
    func applying(_ u: UpdateTransactionInput) -> Transaction {
        let newNative: Int64 = {
            if let native = u.amount_native { return native.kopecks }
            if let amount = u.amount { return amount.kopecks }
            return amountNative
        }()
        let newDateRaw = u.date ?? rawDateTime

        return Transaction(
            id: id,
            userId: userId,
            accountId: u.account_id ?? accountId,
            amount: newNative,
            amountNative: newNative,
            currency: u.currency ?? currency,
            foreignAmount: u.replaceCurrencyFields ? u.foreign_amount : (u.foreign_amount ?? foreignAmount),
            foreignCurrency: u.replaceCurrencyFields ? u.foreign_currency : (u.foreign_currency ?? foreignCurrency),
            fxRate: u.replaceCurrencyFields ? u.fx_rate : (u.fx_rate ?? fxRate),
            description: u.description ?? description,
            categoryId: u.category_id ?? categoryId,
            type: u.type.flatMap(TransactionType.init(rawValue:)) ?? type,
            date: String(newDateRaw.prefix(10)),
            rawDateTime: newDateRaw,
            merchantName: u.merchant_name ?? merchantName,
            merchantFuzzy: merchantFuzzy,
            transferGroupId: transferGroupId,
            paymentSourceAccountId: paymentSourceAccountId,
            autoTransferGroupId: autoTransferGroupId,
            status: "pending",
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
