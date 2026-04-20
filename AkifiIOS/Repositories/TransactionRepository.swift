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
            let p_foreign_amount: Decimal?
            let p_foreign_currency: String?
            let p_fx_rate: Decimal?
            /// When true we emit `p_source_amount` + `p_source_currency`
            /// keys (even if null) so Postgres picks the 10-arg overload.
            /// When false we drop them entirely — 8-arg matches.
            let includeSourceKeys: Bool
            /// When true we emit `p_foreign_amount` + `p_foreign_currency` +
            /// `p_fx_rate` keys so Postgres picks the 13-arg multi-currency
            /// overload (ADR-001 Phase 3). Implies `includeSourceKeys`.
            let includeForeignKeys: Bool

            enum CodingKeys: String, CodingKey {
                case p_account_id, p_category_id, p_amount, p_currency
                case p_date, p_description, p_merchant_name
                case p_payment_source_account_id
                case p_source_amount, p_source_currency
                case p_foreign_amount, p_foreign_currency, p_fx_rate
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
                if includeSourceKeys || includeForeignKeys {
                    try c.encode(p_source_amount, forKey: .p_source_amount)
                    try c.encode(p_source_currency, forKey: .p_source_currency)
                }
                if includeForeignKeys {
                    try c.encode(p_foreign_amount, forKey: .p_foreign_amount)
                    try c.encode(p_foreign_currency, forKey: .p_foreign_currency)
                    try c.encode(p_fx_rate, forKey: .p_fx_rate)
                }
            }
        }
        guard let accountId = input.account_id else {
            throw NSError(
                domain: "TransactionRepository", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "account_id is required for expense with auto-transfer"]
            )
        }
        // The DB has 8/10/13-arg overloads of create_expense_with_auto_transfer
        // (kept around by the ADR-001 Phase-3 migration "for older clients").
        // PostgREST cannot disambiguate when the request is a subset of any
        // of them — a 10-key call matches both the 10-arg AND the 13-arg
        // overload (the extra params default to NULL in the 13-arg) and we
        // get "Could not choose the best candidate function". Always emit
        // ALL 13 keys; only the 13-arg overload has those names so routing
        // is unambiguous.
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
            p_foreign_amount: input.foreign_amount,
            p_foreign_currency: input.foreign_currency,
            p_fx_rate: input.fx_rate,
            includeSourceKeys: true,
            includeForeignKeys: true
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
            let p_foreign_amount: Decimal?
            let p_foreign_currency: String?
            let p_fx_rate: Decimal?
            /// When true we emit the foreign-keys (even as null) so PostgREST
            /// picks the ADR-001 9-arg overload. Otherwise we drop them and
            /// the original 6-arg function handles the call.
            let includeForeignKeys: Bool

            enum CodingKeys: String, CodingKey {
                case p_expense_id, p_amount, p_category_id
                case p_date, p_description, p_merchant_name
                case p_foreign_amount, p_foreign_currency, p_fx_rate
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(p_expense_id, forKey: .p_expense_id)
                try c.encode(p_amount, forKey: .p_amount)
                try c.encode(p_category_id, forKey: .p_category_id)
                try c.encode(p_date, forKey: .p_date)
                try c.encode(p_description, forKey: .p_description)
                try c.encode(p_merchant_name, forKey: .p_merchant_name)
                if includeForeignKeys {
                    try c.encode(p_foreign_amount, forKey: .p_foreign_amount)
                    try c.encode(p_foreign_currency, forKey: .p_foreign_currency)
                    try c.encode(p_fx_rate, forKey: .p_fx_rate)
                }
            }
        }
        // Route to the 9-arg overload whenever foreign-* might need to be
        // SET (any non-nil value) OR explicitly CLEARED (the form is
        // replacing currency fields, e.g. user switched the entry currency
        // back to the account currency). The 6-arg overload preserves
        // existing foreign columns and would silently keep a stale entry.
        let hasForeign = input.foreign_amount != nil && input.foreign_currency != nil
        let includeForeign = hasForeign || input.replaceCurrencyFields
        let params = Params(
            p_expense_id: id,
            p_amount: input.amount,
            p_category_id: input.category_id,
            p_date: input.date,
            p_description: input.description,
            p_merchant_name: input.merchant_name,
            p_foreign_amount: input.foreign_amount,
            p_foreign_currency: input.foreign_currency,
            p_fx_rate: input.fx_rate,
            includeForeignKeys: includeForeign
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
    /// ADR-001: amount in the account's own currency (main units, not kopecks).
    /// Legacy field, kept equal to `amount_native` on every new write.
    let amount: Decimal
    /// ADR-001 canonical amount. Client sends it explicitly so the server
    /// doesn't have to fall back to the Phase 1 compat trigger.
    let amount_native: Decimal
    /// The account's own currency (legacy label, matches `accounts.currency`).
    /// Not the user's entry currency — that lives in `foreign_currency`.
    let currency: String?
    /// Set when the user entered the amount in a currency different from the
    /// account's. `amount_native = foreign_amount × fx_rate`. Both NULL when
    /// the user typed in the account's own currency.
    let foreign_amount: Decimal?
    let foreign_currency: String?
    let fx_rate: Decimal?
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

    init(
        user_id: String,
        account_id: String?,
        amount: Decimal,
        amount_native: Decimal? = nil,
        currency: String?,
        foreign_amount: Decimal? = nil,
        foreign_currency: String? = nil,
        fx_rate: Decimal? = nil,
        type: String,
        date: String,
        description: String?,
        category_id: String?,
        merchant_name: String?,
        transfer_group_id: String? = nil,
        payment_source_account_id: String? = nil,
        source_amount: Decimal? = nil,
        source_currency: String? = nil
    ) {
        self.user_id = user_id; self.account_id = account_id; self.amount = amount
        self.amount_native = amount_native ?? amount
        self.currency = currency
        self.foreign_amount = foreign_amount
        self.foreign_currency = foreign_currency?.uppercased()
        self.fx_rate = fx_rate
        self.type = type; self.date = date
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
        case amount_native, foreign_amount, foreign_currency, fx_rate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user_id = try c.decode(String.self, forKey: .user_id)
        account_id = try c.decodeIfPresent(String.self, forKey: .account_id)
        amount = try c.decode(Decimal.self, forKey: .amount)
        amount_native = try c.decodeIfPresent(Decimal.self, forKey: .amount_native) ?? amount
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        foreign_amount = try c.decodeIfPresent(Decimal.self, forKey: .foreign_amount)
        foreign_currency = try c.decodeIfPresent(String.self, forKey: .foreign_currency)
        fx_rate = try c.decodeIfPresent(Decimal.self, forKey: .fx_rate)
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
    /// ADR-001 canonical amount. If nil and `replaceCurrencyFields` is
    /// false, the server keeps the prior value. If `replaceCurrencyFields`
    /// is true, nil is sent as JSON null and the column is overwritten.
    let amount_native: Decimal?
    let currency: String?
    let foreign_amount: Decimal?
    let foreign_currency: String?
    let fx_rate: Decimal?
    let type: String?
    let date: String?
    let description: String?
    let category_id: String?
    let merchant_name: String?
    let account_id: String?
    /// Internal, not encoded — tells the repo whether to call the auto-transfer RPC.
    let useAutoTransferUpdate: Bool
    /// When true, the encoder emits ALL multi-currency columns
    /// (amount, amount_native, currency, foreign_amount, foreign_currency,
    /// fx_rate) even when nil — JSON null instead of dropping the key.
    /// This is required when the user changes the entry currency in the
    /// form: switching from a foreign-currency entry back to the account
    /// currency must NULL out foreign_amount/foreign_currency/fx_rate, not
    /// leave them as their previous values. Default false preserves the
    /// "patch only what's set" behaviour for callers that touch a single
    /// field (e.g. updating just the description).
    let replaceCurrencyFields: Bool

    init(
        amount: Decimal? = nil,
        amount_native: Decimal? = nil,
        currency: String? = nil,
        foreign_amount: Decimal? = nil,
        foreign_currency: String? = nil,
        fx_rate: Decimal? = nil,
        type: String? = nil,
        date: String? = nil,
        description: String? = nil,
        category_id: String? = nil,
        merchant_name: String? = nil,
        account_id: String? = nil,
        useAutoTransferUpdate: Bool = false,
        replaceCurrencyFields: Bool = false
    ) {
        self.amount = amount
        self.amount_native = amount_native
        self.currency = currency
        self.foreign_amount = foreign_amount
        self.foreign_currency = foreign_currency?.uppercased()
        self.fx_rate = fx_rate
        self.type = type
        self.date = date; self.description = description
        self.category_id = category_id; self.merchant_name = merchant_name
        self.account_id = account_id
        self.useAutoTransferUpdate = useAutoTransferUpdate
        self.replaceCurrencyFields = replaceCurrencyFields
    }

    // Keep `useAutoTransferUpdate` and `replaceCurrencyFields` out of the
    // encoded payload — they're client-only routing flags.
    enum CodingKeys: String, CodingKey {
        case amount, currency, type, date, description, category_id, merchant_name, account_id
        case amount_native, foreign_amount, foreign_currency, fx_rate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = try c.decodeIfPresent(Decimal.self, forKey: .amount)
        amount_native = try c.decodeIfPresent(Decimal.self, forKey: .amount_native)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        foreign_amount = try c.decodeIfPresent(Decimal.self, forKey: .foreign_amount)
        foreign_currency = try c.decodeIfPresent(String.self, forKey: .foreign_currency)
        fx_rate = try c.decodeIfPresent(Decimal.self, forKey: .fx_rate)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        category_id = try c.decodeIfPresent(String.self, forKey: .category_id)
        merchant_name = try c.decodeIfPresent(String.self, forKey: .merchant_name)
        account_id = try c.decodeIfPresent(String.self, forKey: .account_id)
        // Flags never round-trip through the decoder.
        useAutoTransferUpdate = false
        replaceCurrencyFields = false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if replaceCurrencyFields {
            // Always emit — nil → JSON null → DB column cleared.
            try c.encode(amount, forKey: .amount)
            try c.encode(amount_native, forKey: .amount_native)
            try c.encode(currency, forKey: .currency)
            try c.encode(foreign_amount, forKey: .foreign_amount)
            try c.encode(foreign_currency, forKey: .foreign_currency)
            try c.encode(fx_rate, forKey: .fx_rate)
        } else {
            try c.encodeIfPresent(amount, forKey: .amount)
            try c.encodeIfPresent(amount_native, forKey: .amount_native)
            try c.encodeIfPresent(currency, forKey: .currency)
            try c.encodeIfPresent(foreign_amount, forKey: .foreign_amount)
            try c.encodeIfPresent(foreign_currency, forKey: .foreign_currency)
            try c.encodeIfPresent(fx_rate, forKey: .fx_rate)
        }
        try c.encodeIfPresent(type, forKey: .type)
        try c.encodeIfPresent(date, forKey: .date)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(category_id, forKey: .category_id)
        try c.encodeIfPresent(merchant_name, forKey: .merchant_name)
        try c.encodeIfPresent(account_id, forKey: .account_id)
    }
}
