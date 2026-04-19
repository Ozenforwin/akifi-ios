import Foundation

/// Gamified micro-goal. Users pick a type (e.g. "30 days without cafe",
/// "save 500 RUB per week") and the app tracks progress against their
/// transactions. Optionally linked to a `SavingsGoal` so successful
/// contributions flow into the goal's balance.
///
/// All fields mirror the `savings_challenges` table; see migration
/// `20260419120000_savings_challenges.sql`.
struct SavingsChallenge: Codable, Identifiable, Sendable {
    let id: String
    let userId: String
    var type: ChallengeType
    var title: String
    var challengeDescription: String?
    /// Optional target in minor units (e.g. `noCafe` has no target; `weeklyAmount` has one).
    var targetAmount: Int64?
    var durationDays: Int
    var startDate: String        // "yyyy-MM-dd"
    var endDate: String          // "yyyy-MM-dd"
    var status: ChallengeStatus
    var progressAmount: Int64
    /// Category the challenge tracks against (for `noCafe` / `categoryLimit`).
    var categoryId: String?
    /// Link to `SavingsGoal.id` — for `weeklyAmount` challenges successful
    /// periods can feed the linked goal.
    var linkedGoalId: String?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case type, title
        case challengeDescription = "description"
        case targetAmount = "target_amount"
        case durationDays = "duration_days"
        case startDate = "start_date"
        case endDate = "end_date"
        case status
        case progressAmount = "progress_amount"
        case categoryId = "category_id"
        case linkedGoalId = "linked_goal_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(id: String, userId: String, type: ChallengeType, title: String,
         challengeDescription: String? = nil, targetAmount: Int64? = nil,
         durationDays: Int, startDate: String, endDate: String,
         status: ChallengeStatus = .active, progressAmount: Int64 = 0,
         categoryId: String? = nil, linkedGoalId: String? = nil,
         createdAt: String? = nil, updatedAt: String? = nil) {
        self.id = id; self.userId = userId; self.type = type; self.title = title
        self.challengeDescription = challengeDescription
        self.targetAmount = targetAmount; self.durationDays = durationDays
        self.startDate = startDate; self.endDate = endDate; self.status = status
        self.progressAmount = progressAmount; self.categoryId = categoryId
        self.linkedGoalId = linkedGoalId
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userId = try c.decode(String.self, forKey: .userId)
        type = try c.decode(ChallengeType.self, forKey: .type)
        title = try c.decode(String.self, forKey: .title)
        challengeDescription = try c.decodeIfPresent(String.self, forKey: .challengeDescription)
        targetAmount = c.decodeKopecksIfPresent(forKey: .targetAmount)
        durationDays = try c.decode(Int.self, forKey: .durationDays)
        startDate = try c.decode(String.self, forKey: .startDate)
        endDate = try c.decode(String.self, forKey: .endDate)
        status = try c.decodeIfPresent(ChallengeStatus.self, forKey: .status) ?? .active
        progressAmount = c.decodeKopecks(forKey: .progressAmount)
        categoryId = try c.decodeIfPresent(String.self, forKey: .categoryId)
        linkedGoalId = try c.decodeIfPresent(String.self, forKey: .linkedGoalId)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(userId, forKey: .userId)
        try c.encode(type, forKey: .type)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(challengeDescription, forKey: .challengeDescription)
        if let t = targetAmount {
            try c.encode(Double(t) / 100.0, forKey: .targetAmount)
        }
        try c.encode(durationDays, forKey: .durationDays)
        try c.encode(startDate, forKey: .startDate)
        try c.encode(endDate, forKey: .endDate)
        try c.encode(status, forKey: .status)
        try c.encode(Double(progressAmount) / 100.0, forKey: .progressAmount)
        try c.encodeIfPresent(categoryId, forKey: .categoryId)
        try c.encodeIfPresent(linkedGoalId, forKey: .linkedGoalId)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
}

enum ChallengeType: String, Codable, CaseIterable, Sendable {
    /// "30 days without cafe" — counts transactions in the linked category;
    /// success = zero during the period. `progressAmount` stores total
    /// expenses that violated the rule (lower is better).
    case noCafe = "no_cafe"
    /// "Round up to 100 and save the difference" — progress = sum of
    /// round-up deltas across all expense transactions in the period.
    case roundUp = "round_up"
    /// "Save 500 RUB per week" — progress = sum of contributions to the
    /// linked goal (or all savings-category income) during the period.
    /// `targetAmount` = weekly amount.
    case weeklyAmount = "weekly_amount"
    /// "Don't spend more than X on category Y" — progress = total expenses
    /// in `categoryId` during the period; success = progress < targetAmount.
    case categoryLimit = "category_limit"

    var localizedTitle: String {
        switch self {
        case .noCafe: return String(localized: "challenge.type.noCafe")
        case .roundUp: return String(localized: "challenge.type.roundUp")
        case .weeklyAmount: return String(localized: "challenge.type.weeklyAmount")
        case .categoryLimit: return String(localized: "challenge.type.categoryLimit")
        }
    }

    var localizedDescription: String {
        switch self {
        case .noCafe: return String(localized: "challenge.type.noCafe.desc")
        case .roundUp: return String(localized: "challenge.type.roundUp.desc")
        case .weeklyAmount: return String(localized: "challenge.type.weeklyAmount.desc")
        case .categoryLimit: return String(localized: "challenge.type.categoryLimit.desc")
        }
    }

    var icon: String {
        switch self {
        case .noCafe: return "☕"
        case .roundUp: return "🪙"
        case .weeklyAmount: return "📅"
        case .categoryLimit: return "🎯"
        }
    }

    /// True if the challenge type requires `targetAmount` to be set.
    var requiresTarget: Bool {
        switch self {
        case .weeklyAmount, .categoryLimit: return true
        case .noCafe, .roundUp: return false
        }
    }

    /// True if the challenge type requires `categoryId` to be set.
    var requiresCategory: Bool {
        switch self {
        case .noCafe, .categoryLimit: return true
        case .roundUp, .weeklyAmount: return false
        }
    }
}

enum ChallengeStatus: String, Codable, Sendable {
    case active
    case completed
    case abandoned
}

extension SavingsChallenge {
    /// Fraction of duration elapsed since `startDate` clamped to 0...1.
    /// Used for time-progress UI.
    var timeProgress: Double {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        guard let start = df.date(from: startDate),
              let end = df.date(from: endDate) else { return 0 }
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 1 }
        let elapsed = Date().timeIntervalSince(start)
        return max(0, min(1, elapsed / total))
    }

    /// Days remaining until `endDate`, never negative.
    var daysRemaining: Int {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        guard let end = df.date(from: endDate) else { return 0 }
        let comps = Calendar.current.dateComponents([.day], from: Date(), to: end)
        return max(0, comps.day ?? 0)
    }

    /// Success/progress fraction per challenge semantics; 1.0 = complete.
    /// Note: `noCafe` returns 1.0 only when `progressAmount == 0` — any
    /// violation pulls it below that.
    var successFraction: Double {
        switch type {
        case .noCafe:
            return progressAmount == 0 ? 1.0 : 0.0
        case .categoryLimit:
            guard let target = targetAmount, target > 0 else { return 0 }
            return max(0, 1 - Double(progressAmount) / Double(target))
        case .weeklyAmount, .roundUp:
            guard let target = targetAmount, target > 0 else { return 0 }
            return min(1.0, Double(progressAmount) / Double(target))
        }
    }
}
