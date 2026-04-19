import Foundation
import Supabase

final class TransactionRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    func fetchAll(accountId: String? = nil, from: String? = nil, to: String? = nil) async throws -> [Transaction] {
        var query = supabase
            .from("transactions")
            .select()

        if let accountId {
            query = query.eq("account_id", value: accountId)
        }
        if let from {
            query = query.gte("date", value: from)
        }
        if let to {
            query = query.lte("date", value: to)
        }

        return try await query
            .order("date", ascending: false)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func currentUserId() async throws -> String {
        try await SupabaseManager.shared.currentUserId()
    }

    /// Creates a transaction. If this is an expense with a different
    /// `payment_source_account_id` than `account_id`, routes through the
    /// `create_expense_with_auto_transfer` RPC — atomic creation of the
    /// expense + matching transfer pair. Income/transfer/simple-expense
    /// flows fall back to a plain INSERT.
    func create(_ input: CreateTransactionInput) async throws -> Transaction {
        let shouldUseRPC = input.type == TransactionType.expense.rawValue
            && input.payment_source_account_id != nil
            && input.payment_source_account_id != input.account_id
            && input.transfer_group_id == nil

        if shouldUseRPC {
            return try await createExpenseWithAutoTransfer(input)
        }

        return try await supabase
            .from("transactions")
            .insert(input)
            .select()
            .single()
            .execute()
            .value
    }

    private func createExpenseWithAutoTransfer(_ input: CreateTransactionInput) async throws -> Transaction {
        // PostgREST matches RPC overloads by the exact set of argument *names*
        // present in the JSON body. Swift's default Encodable DROPS keys whose
        // value is nil, which would make the 8-arg signature no longer match
        // the 10-arg overload (or vice versa), returning "Could not find the
        // function". Force all keys into the payload by using a custom
        // encode(to:) that emits JSON null for missing fields.
        //
        // Routing between the two overloads: when `source_amount` +
        // `source_currency` are both non-nil we include them in the payload
        // → Postgres routes to the 10-arg cross-currency overload. When
        // they're nil we DROP those keys from the payload → Postgres routes
        // to the 8-arg same-currency version.
        struct Params: Encodable {
            let p_account_id: String
            let p_category_id: String?
            let p_amount: Decimal
            let p_currency: String
            let p_date: String
            let p_description: String?
            let p_merchant_name: String?
            let p_payment_source_account_id: String?
            let p_source_amount: Decimal?
            let p_source_currency: String?
            /// When true we emit `p_source_amount` + `p_source_currency`
            /// keys (even if null) so Postgres picks the 10-arg overload.
            /// When false we drop them entirely — 8-arg matches.
            let includeSourceKeys: Bool

            enum CodingKeys: String, CodingKey {
                case p_account_id, p_category_id, p_amount, p_currency
                case p_date, p_description, p_merchant_name
                case p_payment_source_account_id
                case p_source_amount, p_source_currency
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(p_account_id, forKey: .p_account_id)
                try c.encode(p_category_id, forKey: .p_category_id)
                try c.encode(p_amount, forKey: .p_amount)
                try c.encode(p_currency, forKey: .p_currency)
                try c.encode(p_date, forKey: .p_date)
                try c.encode(p_description, forKey: .p_description)
                try c.encode(p_merchant_name, forKey: .p_merchant_name)
                try c.encode(p_payment_source_account_id, forKey: .p_payment_source_account_id)
                if includeSourceKeys {
                    try c.encode(p_source_amount, forKey: .p_source_amount)
                    try c.encode(p_source_currency, forKey: .p_source_currency)
                }
            }
        }
        guard let accountId = input.account_id else {
            throw NSError(
                domain: "TransactionRepository", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "account_id is required for expense with auto-transfer"]
            )
        }
        let isCrossCurrency = input.source_amount != nil && input.source_currency != nil
        let params = Params(
            p_account_id: accountId,
            p_category_id: input.category_id,
            p_amount: input.amount,
            p_currency: input.currency ?? "RUB",
            p_date: input.date,
            p_description: input.description,
            p_merchant_name: input.merchant_name,
            p_payment_source_account_id: input.payment_source_account_id,
            p_source_amount: input.source_amount,
            p_source_currency: input.source_currency,
            includeSourceKeys: isCrossCurrency
        )

        // RPC returns UUID as a JSON string → decode and re-fetch the row.
        let newId: String = try await supabase
            .rpc("create_expense_with_auto_transfer", params: params)
            .execute()
            .value

        return try await supabase
            .from("transactions")
            .select()
            .eq("id", value: newId)
            .single()
            .execute()
            .value
    }

    /// Updates a transaction. Expense-with-auto-transfer routes through the
    /// `update_expense_with_auto_transfer` RPC so the transfer pair stays
    /// synchronised. Plain transactions hit the table directly.
    func update(id: String, _ input: UpdateTransactionInput) async throws {
        if input.useAutoTransferUpdate {
            try await updateExpenseWithAutoTransfer(id: id, input)
            return
        }

        try await supabase
            .from("transactions")
            .update(input)
            .eq("id", value: id)
            .execute()
    }

    private func updateExpenseWithAutoTransfer(id: String, _ input: UpdateTransactionInput) async throws {
        // See note in createExpenseWithAutoTransfer — must emit null keys,
        // not omit them, so PostgREST matches the 6-arg signature.
        struct Params: Encodable {
            let p_expense_id: String
            let p_amount: Decimal?
            let p_category_id: String?
            let p_date: String?
            let p_description: String?
            let p_merchant_name: String?

            enum CodingKeys: String, CodingKey {
                case p_expense_id, p_amount, p_category_id
                case p_date, p_description, p_merchant_name
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(p_expense_id, forKey: .p_expense_id)
                try c.encode(p_amount, forKey: .p_amount)
                try c.encode(p_category_id, forKey: .p_category_id)
                try c.encode(p_date, forKey: .p_date)
                try c.encode(p_description, forKey: .p_description)
                try c.encode(p_merchant_name, forKey: .p_merchant_name)
            }
        }
        let params = Params(
            p_expense_id: id,
            p_amount: input.amount,
            p_category_id: input.category_id,
            p_date: input.date,
            p_description: input.description,
            p_merchant_name: input.merchant_name
        )
        try await supabase
            .rpc("update_expense_with_auto_transfer", params: params)
            .execute()
    }

    /// Deletes a transaction. If it's an expense with an auto-transfer
    /// group, routes through `delete_expense_with_auto_transfer` to remove
    /// all three rows atomically.
    func delete(id: String) async throws {
        // Inspect the row first so we know whether it's part of an auto-transfer triple.
        let row = try await supabase
            .from("transactions")
            .select("id, auto_transfer_group_id, type")
            .eq("id", value: id)
            .single()
            .execute()
            .data

        struct Meta: Decodable {
            let id: String
            let auto_transfer_group_id: String?
            let type: String
        }
        let meta = try JSONDecoder().decode(Meta.self, from: row)

        // Auto-transfer triplet — always delete via RPC, which removes all
        // three rows (expense + pair).
        if meta.auto_transfer_group_id != nil {
            struct Params: Encodable { let p_expense_id: String }
            try await supabase
                .rpc("delete_expense_with_auto_transfer", params: Params(p_expense_id: id))
                .execute()
            return
        }

        try await supabase
            .from("transactions")
            .delete()
            .eq("id", value: id)
            .execute()
    }
}

struct CreateTransactionInput: Codable, Sendable {
    let user_id: String
    let account_id: String?
    let amount: Decimal
    let currency: String?
    let type: String
    let date: String
    let description: String?
    let category_id: String?
    let merchant_name: String?
    let transfer_group_id: String?
    /// When non-nil and different from `account_id`, routes through the
    /// auto-transfer RPC on the server.
    let payment_source_account_id: String?
    /// Cross-currency source amount — expressed in `source_currency`. Only
    /// present when source account's currency differs from target. Routes
    /// the RPC call to the 10-arg overload.
    let source_amount: Decimal?
    let source_currency: String?

    init(user_id: String, account_id: String?, amount: Decimal, currency: String?, type: String, date: String, description: String?, category_id: String?, merchant_name: String?, transfer_group_id: String? = nil, payment_source_account_id: String? = nil, source_amount: Decimal? = nil, source_currency: String? = nil) {
        self.user_id = user_id; self.account_id = account_id; self.amount = amount
        self.currency = currency; self.type = type; self.date = date
        self.description = description; self.category_id = category_id
        self.merchant_name = merchant_name; self.transfer_group_id = transfer_group_id
        self.payment_source_account_id = payment_source_account_id
        self.source_amount = source_amount
        self.source_currency = source_currency
    }

    // `source_amount` / `source_currency` are client-only — they only exist
    // to route the RPC overload. Drop them from the direct-INSERT payload
    // so the `transactions` table doesn't reject unknown columns.
    enum CodingKeys: String, CodingKey {
        case user_id, account_id, amount, currency, type, date, description
        case category_id, merchant_name, transfer_group_id
        case payment_source_account_id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user_id = try c.decode(String.self, forKey: .user_id)
        account_id = try c.decodeIfPresent(String.self, forKey: .account_id)
        amount = try c.decode(Decimal.self, forKey: .amount)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        type = try c.decode(String.self, forKey: .type)
        date = try c.decode(String.self, forKey: .date)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        category_id = try c.decodeIfPresent(String.self, forKey: .category_id)
        merchant_name = try c.decodeIfPresent(String.self, forKey: .merchant_name)
        transfer_group_id = try c.decodeIfPresent(String.self, forKey: .transfer_group_id)
        payment_source_account_id = try c.decodeIfPresent(String.self, forKey: .payment_source_account_id)
        source_amount = nil
        source_currency = nil
    }
}

struct UpdateTransactionInput: Codable, Sendable {
    let amount: Decimal?
    let currency: String?
    let type: String?
    let date: String?
    let description: String?
    let category_id: String?
    let merchant_name: String?
    let account_id: String?
    /// Internal, not encoded — tells the repo whether to call the auto-transfer RPC.
    let useAutoTransferUpdate: Bool

    init(amount: Decimal? = nil, currency: String? = nil, type: String? = nil, date: String? = nil, description: String? = nil, category_id: String? = nil, merchant_name: String? = nil, account_id: String? = nil, useAutoTransferUpdate: Bool = false) {
        self.amount = amount; self.currency = currency; self.type = type
        self.date = date; self.description = description
        self.category_id = category_id; self.merchant_name = merchant_name
        self.account_id = account_id
        self.useAutoTransferUpdate = useAutoTransferUpdate
    }

    // Keep `useAutoTransferUpdate` out of the encoded payload — it's a client-only flag.
    enum CodingKeys: String, CodingKey {
        case amount, currency, type, date, description, category_id, merchant_name, account_id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = try c.decodeIfPresent(Decimal.self, forKey: .amount)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        category_id = try c.decodeIfPresent(String.self, forKey: .category_id)
        merchant_name = try c.decodeIfPresent(String.self, forKey: .merchant_name)
        account_id = try c.decodeIfPresent(String.self, forKey: .account_id)
        // Flag is never persisted — default to false when decoding.
        useAutoTransferUpdate = false
    }
}
