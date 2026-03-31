import Foundation

// MARK: - Assistant Response (Full backend response)

struct AssistantResponse: Codable, Sendable {
    let ok: Bool?
    let requestId: String?
    let conversationId: String?
    let messageId: String?
    let status: AssistantResponseStatus?
    let answer: String?
    let facts: [String]?
    let actions: [AssistantAction]?
    let followUps: [String]?
    let intent: String?
    let period: String?
    let evidence: [AnomalyEvidence]?
    let confidence: Double?
    let recommendedActions: [RecommendedAction]?
    let explainability: String?

    /// Computed for backward compatibility
    var reply: String { answer ?? "" }

    enum CodingKeys: String, CodingKey {
        case ok
        case requestId = "request_id"
        case conversationId = "conversation_id"
        case messageId = "message_id"
        case status, answer, facts, actions
        case followUps = "follow_ups"
        case intent, period, evidence, confidence
        case recommendedActions = "recommended_actions"
        case explainability
    }
}

enum AssistantResponseStatus: String, Codable, Sendable {
    case success
    case fallback
    case limited
}

// MARK: - Assistant Action

struct AssistantAction: Codable, Sendable, Identifiable {
    var id: String { "\(type.rawValue)_\(label)" }
    let type: AssistantActionType
    let label: String
    let payload: ActionPayload?
}

enum AssistantActionType: String, Codable, Sendable {
    case openTransactions = "open_transactions"
    case openBudgetTab = "open_budget_tab"
    case openAddExpense = "open_add_expense"
    case openAddIncome = "open_add_income"
    case openSavings = "open_savings"
    case createBudgetSuggestion = "create_budget_suggestion"
    case createTransaction = "create_transaction"
    case editTransaction = "edit_transaction"
    case deleteTransaction = "delete_transaction"
    case editBudget = "edit_budget"
    case savingsContribute = "savings_contribute"
    case smartBudgetCreate = "smart_budget_create"
    case createSavingsGoal = "create_savings_goal"

    var isNavigationAction: Bool {
        switch self {
        case .openTransactions, .openBudgetTab, .openAddExpense,
             .openAddIncome, .openSavings:
            return true
        default:
            return false
        }
    }

    var isExecutionAction: Bool {
        !isNavigationAction
    }

    var riskLevel: ActionRiskLevel {
        switch self {
        case .openTransactions, .openBudgetTab, .openAddExpense,
             .openAddIncome, .openSavings:
            return .low
        case .createTransaction, .createBudgetSuggestion,
             .smartBudgetCreate, .createSavingsGoal, .savingsContribute:
            return .medium
        case .editTransaction, .editBudget:
            return .medium
        case .deleteTransaction:
            return .high
        }
    }
}

struct ActionPayload: Codable, Sendable {
    // Navigation payloads
    let txIds: [String]?
    let category: String?
    let merchant: String?
    let minAmount: Double?

    // Transaction payloads
    let amount: Double?
    let type: String?
    let categoryId: String?
    let accountId: String?
    let description: String?
    let date: String?

    // Budget payloads
    let budgetId: String?
    let categoryIds: [String]?
    let accountIds: [String]?
    let periodType: String?
    let budgetType: String?

    // Savings payloads
    let goalId: String?
    let goalName: String?
    let targetAmount: Double?

    enum CodingKeys: String, CodingKey {
        case txIds = "tx_ids"
        case category, merchant
        case minAmount = "min_amount"
        case amount, type
        case categoryId = "category_id"
        case accountId = "account_id"
        case description, date
        case budgetId = "budget_id"
        case categoryIds = "category_ids"
        case accountIds = "account_ids"
        case periodType = "period_type"
        case budgetType = "budget_type"
        case goalId = "goal_id"
        case goalName = "goal_name"
        case targetAmount = "target_amount"
    }
}

// MARK: - Action Preview & Execution

enum ActionRiskLevel: String, Codable, Sendable {
    case low, medium, high
}

struct ActionPreview: Codable, Sendable {
    let plan: String
    let risk: ActionRiskLevel
    let changes: [String]
    let reversible: Bool
}

struct ActionResponse: Codable, Sendable {
    let ok: Bool
    let actionRunId: String?
    let mode: ActionMode?
    let actionType: String?
    let preview: ActionPreview?
    let result: [String: AnyCodableValue]?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case actionRunId = "action_run_id"
        case mode
        case actionType = "action_type"
        case preview, result, error
    }
}

enum ActionMode: String, Codable, Sendable {
    case preview, confirm
}

// MARK: - Anomaly Evidence

struct AnomalyEvidence: Codable, Sendable, Identifiable {
    var id: String { "\(type.rawValue)_\(label)" }
    let type: AnomalyEvidenceType
    let label: String
    let currentValue: Double
    let baselineValue: Double
    let deltaPercent: Double
    let txRefs: [String]?
    let heatmap: [HeatmapEntry]?

    enum CodingKeys: String, CodingKey {
        case type, label
        case currentValue = "current_value"
        case baselineValue = "baseline_value"
        case deltaPercent = "delta_percent"
        case txRefs = "tx_refs"
        case heatmap
    }
}

enum AnomalyEvidenceType: String, Codable, Sendable {
    case categorySpike = "category_spike"
    case merchantSpike = "merchant_spike"
    case singleLargeTx = "single_large_tx"
    case frequencySpike = "frequency_spike"

    var icon: String {
        switch self {
        case .categorySpike: return "chart.bar.fill"
        case .merchantSpike: return "storefront.fill"
        case .singleLargeTx: return "banknote.fill"
        case .frequencySpike: return "bolt.fill"
        }
    }

    var emoji: String {
        switch self {
        case .categorySpike: return "📊"
        case .merchantSpike: return "🏪"
        case .singleLargeTx: return "💸"
        case .frequencySpike: return "⚡"
        }
    }
}

struct HeatmapEntry: Codable, Sendable {
    let day: Int
    let count: Int
}

// MARK: - Recommended Action

struct RecommendedAction: Codable, Sendable, Identifiable {
    let id: String
    let label: String
    let actionType: RecommendedActionType
    let payload: RecommendedActionPayload?

    enum CodingKeys: String, CodingKey {
        case id, label
        case actionType = "action_type"
        case payload
    }
}

enum RecommendedActionType: String, Codable, Sendable {
    case openTransactions = "open_transactions"
    case openBudgetTab = "open_budget_tab"
    case openAddExpense = "open_add_expense"
    case openAddIncome = "open_add_income"
}

struct RecommendedActionPayload: Codable, Sendable {
    let txIds: [String]?
    let category: String?
    let merchant: String?
    let minAmount: Double?

    enum CodingKeys: String, CodingKey {
        case txIds = "tx_ids"
        case category, merchant
        case minAmount = "min_amount"
    }
}

// MARK: - AI Feedback

struct AIFeedback: Encodable, Sendable {
    let requestId: String
    let score: Int // 1 or -1
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case score, reason
    }
}

enum FeedbackReason: String, CaseIterable, Sendable {
    case wrongData = "wrong_data"
    case notHelpful = "not_helpful"
    case misunderstood = "misunderstood"
    case tooVague = "too_vague"
    case other = "other"

    var displayName: String {
        switch self {
        case .wrongData: return String(localized: "feedback.wrongData")
        case .notHelpful: return String(localized: "feedback.notHelpful")
        case .misunderstood: return String(localized: "feedback.misunderstood")
        case .tooVague: return String(localized: "feedback.tooVague")
        case .other: return String(localized: "feedback.other")
        }
    }
}

// MARK: - AI User Settings

struct AIUserSettings: Codable, Sendable {
    var tone: AITone
    var digestOptIn: Bool
    var quietHoursStart: Int?
    var quietHoursEnd: Int?
    var timezone: String?

    enum CodingKeys: String, CodingKey {
        case tone
        case digestOptIn = "digest_opt_in"
        case quietHoursStart = "quiet_hours_start"
        case quietHoursEnd = "quiet_hours_end"
        case timezone
    }

    static let `default` = AIUserSettings(
        tone: .balanced,
        digestOptIn: false,
        quietHoursStart: nil,
        quietHoursEnd: nil,
        timezone: TimeZone.current.identifier
    )
}

enum AITone: String, Codable, Sendable, CaseIterable {
    case balanced
    case strict
    case friendly

    var displayName: String {
        switch self {
        case .balanced: return String(localized: "tone.balanced")
        case .strict: return String(localized: "tone.strict")
        case .friendly: return String(localized: "tone.friendly")
        }
    }

    var description: String {
        switch self {
        case .balanced: return String(localized: "tone.balanced.description")
        case .strict: return String(localized: "tone.strict.description")
        case .friendly: return String(localized: "tone.friendly.description")
        }
    }
}

// MARK: - Error Classification

enum AssistantErrorType: Sendable {
    case auth
    case rateLimit
    case timeout
    case network
    case notDeployed
    case validation(String)
    case unknown(String)

    var userMessage: String {
        switch self {
        case .auth:
            return String(localized: "error.auth.sessionExpired")
        case .rateLimit:
            return String(localized: "error.rateLimit")
        case .timeout:
            return String(localized: "error.timeout")
        case .network:
            return String(localized: "error.noInternet")
        case .notDeployed:
            return String(localized: "error.aiUnavailable")
        case .validation(let msg):
            return msg
        case .unknown(let msg):
            return "\(String(localized: "error.prefix")): \(msg)"
        }
    }

    static func classify(_ error: Error) -> AssistantErrorType {
        let message = error.localizedDescription.lowercased()

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timeout
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return .network
            default:
                break
            }
        }

        if message.contains("jwt") || message.contains("auth") || message.contains("token")
            || message.contains("401") {
            return .auth
        }
        if message.contains("rate") || message.contains("limit") || message.contains("429")
            || message.contains("quota") {
            return .rateLimit
        }
        if message.contains("timeout") || message.contains("timed out") {
            return .timeout
        }
        if message.contains("404") || message.contains("not found")
            || message.contains("not deployed") {
            return .notDeployed
        }
        if message.contains("network") || message.contains("connection")
            || message.contains("internet") {
            return .network
        }

        return .unknown(error.localizedDescription)
    }
}

// MARK: - Chat Message (UI-level enriched message)

struct ChatMessage: Identifiable, Sendable {
    let id: String
    let role: MessageRole
    let content: String
    var facts: [String]?
    var actions: [AssistantAction]?
    var followUps: [String]?
    var requestId: String?
    var messageId: String?
    var feedback: Int?  // 1 or -1
    var evidence: [AnomalyEvidence]?
    var confidence: Double?
    var recommendedActions: [RecommendedAction]?
    var explainability: String?
    var actionPreview: ActionPreviewState?
    var actionResult: ActionResultState?

    struct ActionPreviewState: Sendable {
        let action: AssistantAction
        let preview: ActionPreview
        let actionRunId: String?
    }

    struct ActionResultState: Sendable {
        let success: Bool
        let message: String
    }

    static func fromUser(text: String, conversationId: String) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            role: .user,
            content: text
        )
    }

    static func fromResponse(_ response: AssistantResponse) -> ChatMessage {
        ChatMessage(
            id: response.messageId ?? UUID().uuidString,
            role: .assistant,
            content: response.reply,
            facts: response.facts,
            actions: response.actions,
            followUps: response.followUps,
            requestId: response.requestId,
            messageId: response.messageId,
            evidence: response.evidence,
            confidence: response.confidence,
            recommendedActions: response.recommendedActions,
            explainability: response.explainability
        )
    }

    static func fromAiMessage(_ msg: AiMessage) -> ChatMessage {
        ChatMessage(
            id: msg.id,
            role: msg.role,
            content: msg.content
        )
    }
}

// MARK: - AnyCodableValue (for dynamic JSON)

enum AnyCodableValue: Codable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode(Int.self) { self = .int(v) }
        else if let v = try? container.decode(Double.self) { self = .double(v) }
        else if let v = try? container.decode(String.self) { self = .string(v) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }
}
