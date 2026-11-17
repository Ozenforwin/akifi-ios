import Foundation

/// Lifecycle state of a subscription.
///
/// Supersedes the legacy `is_active` boolean. Backward compat:
/// old clients (v1.2.2) that only read `is_active` keep working thanks to a
/// DB trigger that mirrors `status == .active` → `is_active = true`.
///
/// - `.active`    — charges continue, reminders scheduled, shown in "Active" list.
/// - `.paused`    — user temporarily paused it; reminders cancelled; auto-recalc frozen.
/// - `.cancelled` — ended; reminders cancelled; shown in archive only.
enum SubscriptionTrackerStatus: String, Codable, CaseIterable, Sendable {
    case active
    case paused
    case cancelled

    var localizedName: String {
        switch self {
        case .active: return String(localized: "subscriptions.status.active")
        case .paused: return String(localized: "subscriptions.status.paused")
        case .cancelled: return String(localized: "subscriptions.status.cancelled")
        }
    }

    var systemImage: String {
        switch self {
        case .active: return "play.circle.fill"
        case .paused: return "pause.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        }
    }
}

struct SubscriptionTracker: Codable, Identifiable, Sendable {
    let id: String
    let userId: String
    var serviceName: String
    var amount: Int64
    var currency: String?
    var billingPeriod: BillingPeriod
    var startDate: String
    var lastPaymentDate: String?
    var nextPaymentDate: String?
    var categoryId: String?
    var accountId: String?
    var reminderDays: Int
    var iconColor: String?
    var isActive: Bool
    var status: SubscriptionTrackerStatus
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case serviceName = "service_name"
        case amount, currency
        case billingPeriod = "billing_period"
        case startDate = "start_date"
        case lastPaymentDate = "last_payment_date"
        case nextPaymentDate = "next_payment_date"
        case categoryId = "category_id"
        case accountId = "account_id"
        case reminderDays = "reminder_days"
        case iconColor = "icon_color"
        case isActive = "is_active"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(id: String, userId: String, serviceName: String, amount: Int64, currency: String? = nil,
         billingPeriod: BillingPeriod, startDate: String, lastPaymentDate: String? = nil,
         nextPaymentDate: String? = nil, categoryId: String? = nil, accountId: String? = nil,
         reminderDays: Int = 1,
         iconColor: String? = nil, isActive: Bool = true, status: SubscriptionTrackerStatus? = nil,
         createdAt: String? = nil, updatedAt: String? = nil) {
        self.id = id; self.userId = userId; self.serviceName = serviceName; self.amount = amount
        self.currency = currency; self.billingPeriod = billingPeriod; self.startDate = startDate
        self.lastPaymentDate = lastPaymentDate
        self.nextPaymentDate = nextPaymentDate; self.categoryId = categoryId
        self.accountId = accountId
        self.reminderDays = reminderDays
        self.iconColor = iconColor; self.isActive = isActive
        self.status = status ?? (isActive ? .active : .cancelled)
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userId = try container.decode(String.self, forKey: .userId)
        serviceName = try container.decode(String.self, forKey: .serviceName)
        amount = container.decodeKopecks(forKey: .amount)
        currency = try container.decodeIfPresent(String.self, forKey: .currency)
        billingPeriod = try container.decode(BillingPeriod.self, forKey: .billingPeriod)
        startDate = try container.decode(String.self, forKey: .startDate)
        lastPaymentDate = try container.decodeIfPresent(String.self, forKey: .lastPaymentDate)
        nextPaymentDate = try container.decodeIfPresent(String.self, forKey: .nextPaymentDate)
        categoryId = try container.decodeIfPresent(String.self, forKey: .categoryId)
        accountId = try container.decodeIfPresent(String.self, forKey: .accountId)
        reminderDays = try container.decodeIfPresent(Int.self, forKey: .reminderDays) ?? 1
        iconColor = try container.decodeIfPresent(String.self, forKey: .iconColor)
        let decodedIsActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        isActive = decodedIsActive
        // Backward compat: if `status` is missing (pre-v1.2.3 payloads or cached data),
        // derive it from `is_active`.
        if let rawStatus = try container.decodeIfPresent(String.self, forKey: .status),
           let decoded = SubscriptionTrackerStatus(rawValue: rawStatus) {
            status = decoded
        } else {
            status = decodedIsActive ? .active : .cancelled
        }
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(userId, forKey: .userId)
        try container.encode(serviceName, forKey: .serviceName)
        try container.encode(Double(amount) / 100.0, forKey: .amount)
        try container.encodeIfPresent(currency, forKey: .currency)
        try container.encode(billingPeriod, forKey: .billingPeriod)
        try container.encode(startDate, forKey: .startDate)
        try container.encodeIfPresent(lastPaymentDate, forKey: .lastPaymentDate)
        try container.encodeIfPresent(nextPaymentDate, forKey: .nextPaymentDate)
        try container.encodeIfPresent(categoryId, forKey: .categoryId)
        try container.encodeIfPresent(accountId, forKey: .accountId)
        try container.encode(reminderDays, forKey: .reminderDays)
        try container.encodeIfPresent(iconColor, forKey: .iconColor)
        try container.encode(isActive, forKey: .isActive)
        try container.encode(status.rawValue, forKey: .status)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }

    // MARK: - Cycle Progress

    /// Days remaining until next payment
    var daysRemaining: Int {
        max(0, signedDaysToNextPayment)
    }

    /// Days the scheduled charge is in the past. `0` when it is today or
    /// still ahead. Surfaced instead of "today" so a charge the server
    /// missed (cron down, database down) is visible, not disguised.
    var daysOverdue: Int {
        max(0, -signedDaysToNextPayment)
    }

    var isOverdue: Bool { daysOverdue > 0 }

    /// Negative when `nextPaymentDate` is in the past.
    private var signedDaysToNextPayment: Int {
        guard let next = SubscriptionDateEngine.parseDbDate(nextPaymentDate) else { return 0 }
        return SubscriptionDateEngine.daysBetween(Date(), next)
    }

    /// Progress through current billing cycle (0.0 – 1.0). The cycle starts
    /// at the schedule's previous charge date, so a 31st-of-the-month
    /// subscription runs 28 Feb → 31 Mar, not 28 Feb → 28 Mar.
    var cycleProgress: Double {
        guard let cycleEnd = SubscriptionDateEngine.parseDbDate(nextPaymentDate) else { return 0 }
        let anchor = SubscriptionDateEngine.anchor(for: self) ?? cycleEnd
        let cycleStart = SubscriptionDateEngine.previousChargeDate(
            before: cycleEnd, anchor: anchor, period: billingPeriod
        )
        let totalDays = max(1, SubscriptionDateEngine.daysBetween(cycleStart, cycleEnd))
        let elapsed = min(totalDays, max(0, SubscriptionDateEngine.daysBetween(cycleStart, Date())))
        return Double(elapsed) / Double(totalDays)
    }
}
