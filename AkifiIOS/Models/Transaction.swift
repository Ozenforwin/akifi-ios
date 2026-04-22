import Foundation

struct Transaction: Codable, Identifiable, Sendable {
    let id: String
    let userId: String
    var accountId: String?
    /// Legacy column. On every new write the server mirrors it from
    /// `amountNative`, so for all post-ADR-001 rows they are equal.
    /// Kept in kopecks (×100 of the DB numeric) for Int64 math.
    ///
    /// ⚠️ Do NOT use for aggregation or display. Summing `.amount` across
    /// accounts with different currencies produces the VND-as-RUB phantom
    /// (ADR-001). Use `amountNative` for account-local math, and
    /// `DataStore.amountInBase(tx)` / `TransactionMath.amountInBase(tx, …)`
    /// for cross-account aggregation. The field is kept public only for the
    /// Codable round-trip and the `TransactionRepository` write-path — CI
    /// lint guards against its use elsewhere.
    @available(*, deprecated, message: "Use tx.amountNative (account-local) or dataStore.amountInBase(tx) (aggregation). See ADR-001.")
    var amount: Int64
    /// ADR-001 canonical amount in the owning account's currency, kopecks.
    /// Populated server-side at migration (backfill = amount) and on every
    /// new write. This is the ONLY field used by post-Phase-3 read-path.
    var amountNative: Int64
    /// Legacy label carried from TMA. Meaning is inconsistent across
    /// historical rows — should be treated as advisory only and not used for
    /// math. New writes keep it equal to `account.currency` for compatibility.
    var currency: String?
    /// User-entered amount in `foreignCurrency` when entry currency differs
    /// from the account currency. In main units (Decimal, not kopecks) since
    /// minor-unit scale is currency-dependent (VND = 0, USD = 2).
    var foreignAmount: Decimal?
    /// ISO code (uppercase) of the currency the user originally entered.
    /// NULL when entry was in account currency.
    var foreignCurrency: String?
    /// Frozen rate at entry time: foreignCurrency → accountCurrency.
    /// `amountNative ≈ foreignAmount × fxRate` (in each currency's own units).
    var fxRate: Decimal?
    var description: String?
    var categoryId: String?
    var type: TransactionType
    var date: String          // "yyyy-MM-dd" for filtering
    var rawDateTime: String   // full timestamp from DB for time display
    var merchantName: String?
    var merchantFuzzy: String?
    var transferGroupId: String?
    /// Optional pointer to the account that actually funded a shared-account
    /// expense. When set and `!= accountId`, a triplet of rows is written:
    /// the expense on target account + transfer-out on source + transfer-in
    /// on target (all sharing `autoTransferGroupId`).
    var paymentSourceAccountId: String?
    /// UUID binding the expense and its auto-generated transfer pair.
    /// All three rows share the same value. `nil` for plain expenses.
    var autoTransferGroupId: String?
    var status: String?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case accountId = "account_id"
        case amount
        case amountNative = "amount_native"
        case currency
        case foreignAmount = "foreign_amount"
        case foreignCurrency = "foreign_currency"
        case fxRate = "fx_rate"
        case description
        case categoryId = "category_id"
        case type
        case date
        case merchantName = "merchant_name"
        case merchantFuzzy = "merchant_normalized"
        case transferGroupId = "transfer_group_id"
        case paymentSourceAccountId = "payment_source_account_id"
        case autoTransferGroupId = "auto_transfer_group_id"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        id: String,
        userId: String,
        accountId: String?,
        amount: Int64,
        amountNative: Int64? = nil,
        currency: String?,
        foreignAmount: Decimal? = nil,
        foreignCurrency: String? = nil,
        fxRate: Decimal? = nil,
        description: String?,
        categoryId: String?,
        type: TransactionType,
        date: String,
        rawDateTime: String? = nil,
        merchantName: String?,
        merchantFuzzy: String?,
        transferGroupId: String?,
        paymentSourceAccountId: String? = nil,
        autoTransferGroupId: String? = nil,
        status: String?,
        createdAt: String?,
        updatedAt: String?
    ) {
        self.id = id; self.userId = userId; self.accountId = accountId; self.amount = amount
        self.amountNative = amountNative ?? amount
        self.currency = currency
        self.foreignAmount = foreignAmount
        self.foreignCurrency = foreignCurrency?.uppercased()
        self.fxRate = fxRate
        self.description = description; self.categoryId = categoryId
        self.type = type; self.date = date; self.rawDateTime = rawDateTime ?? date
        self.merchantName = merchantName; self.merchantFuzzy = merchantFuzzy
        self.transferGroupId = transferGroupId
        self.paymentSourceAccountId = paymentSourceAccountId
        self.autoTransferGroupId = autoTransferGroupId
        self.status = status; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userId = try container.decode(String.self, forKey: .userId)
        accountId = try container.decodeIfPresent(String.self, forKey: .accountId)
        amount = container.decodeKopecks(forKey: .amount)
        // Fallback = amount so legacy rows (before the Phase 1 backfill
        // reached them, or cached snapshots from old builds) still produce a
        // usable balance figure.
        amountNative = container.decodeKopecksIfPresent(forKey: .amountNative) ?? amount
        currency = try container.decodeIfPresent(String.self, forKey: .currency)
        foreignAmount = container.decodeDecimalIfPresent(forKey: .foreignAmount)
        foreignCurrency = try container.decodeIfPresent(String.self, forKey: .foreignCurrency)?.uppercased()
        fxRate = container.decodeDecimalIfPresent(forKey: .fxRate)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        categoryId = try container.decodeIfPresent(String.self, forKey: .categoryId)
        type = try container.decode(TransactionType.self, forKey: .type)
        let rawDate = try container.decode(String.self, forKey: .date)
        rawDateTime = rawDate
        date = String(rawDate.prefix(10))
        merchantName = try container.decodeIfPresent(String.self, forKey: .merchantName)
        merchantFuzzy = try container.decodeIfPresent(String.self, forKey: .merchantFuzzy)
        transferGroupId = try container.decodeIfPresent(String.self, forKey: .transferGroupId)
        paymentSourceAccountId = try container.decodeIfPresent(String.self, forKey: .paymentSourceAccountId)
        autoTransferGroupId = try container.decodeIfPresent(String.self, forKey: .autoTransferGroupId)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(userId, forKey: .userId)
        try container.encodeIfPresent(accountId, forKey: .accountId)
        // Store as rubles (same format as DB) so decode always does ×100
        try container.encode(Double(amount) / 100.0, forKey: .amount)
        // Always emit amount_native — the DB has a NOT NULL check on it.
        try container.encode(Double(amountNative) / 100.0, forKey: .amountNative)
        try container.encodeIfPresent(currency, forKey: .currency)
        try container.encodeIfPresent(foreignAmount, forKey: .foreignAmount)
        try container.encodeIfPresent(foreignCurrency, forKey: .foreignCurrency)
        try container.encodeIfPresent(fxRate, forKey: .fxRate)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(categoryId, forKey: .categoryId)
        try container.encode(type, forKey: .type)
        try container.encode(rawDateTime, forKey: .date)
        try container.encodeIfPresent(merchantName, forKey: .merchantName)
        try container.encodeIfPresent(merchantFuzzy, forKey: .merchantFuzzy)
        try container.encodeIfPresent(transferGroupId, forKey: .transferGroupId)
        try container.encodeIfPresent(paymentSourceAccountId, forKey: .paymentSourceAccountId)
        try container.encodeIfPresent(autoTransferGroupId, forKey: .autoTransferGroupId)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
}

enum TransactionType: String, Codable, Sendable {
    case income
    case expense
    case transfer
}

extension Transaction {
    /// True if this is a transfer between accounts (either type==transfer or has transferGroupId)
    var isTransfer: Bool {
        type == .transfer || transferGroupId != nil
    }

    /// True if this row is one of the two transfer-legs auto-generated by
    /// `create_expense_with_auto_transfer`. Only the expense-leg with the
    /// matching account should surface "Paid from" UI; transfer legs are
    /// usually filtered out of regular listings (they can't be deleted directly).
    var isAutoTransferLeg: Bool {
        autoTransferGroupId != nil && transferGroupId != nil
    }

    /// True when the user entered the transaction in a currency different
    /// from the account currency; drives the "500 000 VND ≈ 1 900 ₽" UI.
    var hasForeignCurrency: Bool {
        foreignCurrency != nil && foreignAmount != nil
    }
}
