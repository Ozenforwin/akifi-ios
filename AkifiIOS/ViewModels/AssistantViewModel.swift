import Foundation

@Observable @MainActor
final class AssistantViewModel {
    var conversations: [AiConversation] = []
    var currentConversation: AiConversation?
    var chatMessages: [ChatMessage] = []
    var inputText = ""
    var isProcessing = false
    var error: String?
    var followUps: [String] = []
    var showConversations = false

    // Action system
    var showActionPreview = false
    var pendingAction: AssistantAction?
    var pendingActionPreview: ActionPreview?
    var pendingActionRunId: String?
    var pendingMessageId: String?
    var actionProcessing = false

    // Feedback
    var showFeedbackSheet = false
    var feedbackMessageId: String?
    var feedbackRequestId: String?

    // Latest response metadata
    var lastEvidence: [AnomalyEvidence]?
    var lastConfidence: Double?
    var lastRecommendedActions: [RecommendedAction]?

    private let repo = AiRepository()

    // MARK: - Conversations

    func loadConversations() async {
        do {
            conversations = try await repo.fetchConversations()
        } catch {
            self.error = AssistantErrorType.classify(error).userMessage
        }
    }

    func startNewConversation() async {
        // Don't create conversation in DB — backend creates it on first message
        currentConversation = nil
        chatMessages = []
        followUps = []
        lastEvidence = nil
        lastConfidence = nil
        lastRecommendedActions = nil
        error = nil
    }

    func selectConversation(_ conversation: AiConversation) async {
        currentConversation = conversation
        do {
            let messages = try await repo.fetchMessages(conversationId: conversation.id)
            chatMessages = messages.map { ChatMessage.fromAiMessage($0) }
            followUps = []
        } catch {
            self.error = AssistantErrorType.classify(error).userMessage
        }
    }

    func archiveConversation(_ conversation: AiConversation) async {
        do {
            try await repo.archiveConversation(id: conversation.id)
            conversations.removeAll { $0.id == conversation.id }
            if currentConversation?.id == conversation.id {
                currentConversation = nil
                chatMessages = []
            }
        } catch {
            self.error = AssistantErrorType.classify(error).userMessage
        }
    }

    // MARK: - Send Message

    func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Validate length
        guard text.count >= 2 else {
            self.error = "Минимум 2 символа"
            return
        }
        guard text.count <= 500 else {
            self.error = "Максимум 500 символов"
            return
        }

        inputText = ""

        // Use existing conversation_id or nil (backend creates conversation)
        let conversationId = currentConversation?.id

        // Add user message optimistically
        let userMsg = ChatMessage.fromUser(text: text, conversationId: conversationId ?? "")
        chatMessages.append(userMsg)

        isProcessing = true
        error = nil

        await repo.logAnalyticsEvent(event: "ai_prompt_sent")

        do {
            let response = try await repo.sendMessage(
                conversationId: conversationId,
                content: text
            )

            // If backend created a new conversation, save it
            if currentConversation == nil, let newConvId = response.conversationId {
                let conv = AiConversation(
                    id: newConvId,
                    userId: "",
                    title: nil,
                    source: "ios",
                    isArchived: false,
                    createdAt: nil,
                    updatedAt: nil
                )
                currentConversation = conv
                conversations.insert(conv, at: 0)
            }

            let assistantMsg = ChatMessage.fromResponse(response)
            chatMessages.append(assistantMsg)

            followUps = response.followUps ?? []
            lastEvidence = response.evidence
            lastConfidence = response.confidence
            lastRecommendedActions = response.recommendedActions

            await repo.logAnalyticsEvent(event: "ai_response_ok")
        } catch {
            let classified = AssistantErrorType.classify(error)
            self.error = classified.userMessage
            await repo.logAnalyticsEvent(event: "ai_response_error")
        }

        isProcessing = false
    }

    func sendFollowUp(_ text: String) async {
        inputText = text
        await repo.logAnalyticsEvent(event: "ai_followup_clicked")
        await send()
    }

    // MARK: - Actions

    func requestActionPreview(_ action: AssistantAction, messageId: String?) async {
        guard let conversationId = currentConversation?.id else { return }
        guard let msgId = messageId else { return }

        pendingAction = action
        pendingMessageId = msgId
        actionProcessing = true

        await repo.logAnalyticsEvent(event: "ai_action_clicked")

        do {
            let response = try await repo.previewAction(
                conversationId: conversationId,
                messageId: msgId,
                action: action
            )

            if let preview = response.preview {
                pendingActionPreview = preview
                pendingActionRunId = response.actionRunId
                showActionPreview = true
                await repo.logAnalyticsEvent(event: "ai_action_previewed")
            }
        } catch {
            self.error = AssistantErrorType.classify(error).userMessage
        }

        actionProcessing = false
    }

    func confirmAction() async {
        guard let action = pendingAction,
              let conversationId = currentConversation?.id,
              let msgId = pendingMessageId,
              let runId = pendingActionRunId else { return }

        actionProcessing = true

        do {
            let response = try await repo.confirmAction(
                conversationId: conversationId,
                messageId: msgId,
                actionRunId: runId,
                action: action
            )

            // Update the message with result
            if let index = chatMessages.lastIndex(where: { $0.messageId == msgId }) {
                chatMessages[index].actionResult = ChatMessage.ActionResultState(
                    success: response.ok,
                    message: response.ok ? "Действие выполнено" : (response.error ?? "Ошибка выполнения")
                )
            }

            await repo.logAnalyticsEvent(event: response.ok ? "ai_action_executed" : "ai_action_failed")
        } catch {
            self.error = AssistantErrorType.classify(error).userMessage
            await repo.logAnalyticsEvent(event: "ai_action_failed")
        }

        showActionPreview = false
        pendingAction = nil
        pendingActionPreview = nil
        pendingActionRunId = nil
        pendingMessageId = nil
        actionProcessing = false
    }

    func cancelAction() {
        showActionPreview = false
        pendingAction = nil
        pendingActionPreview = nil
        pendingActionRunId = nil
        pendingMessageId = nil
    }

    // MARK: - Feedback

    func submitPositiveFeedback(for message: ChatMessage) async {
        guard let requestId = message.requestId else { return }
        do {
            try await repo.submitFeedback(requestId: requestId, score: 1, reason: nil)
            if let index = chatMessages.firstIndex(where: { $0.id == message.id }) {
                chatMessages[index].feedback = 1
            }
            await repo.logAnalyticsEvent(event: "ai_feedback_sent", metadata: ["score": "1"])
        } catch {
            // Non-critical
        }
    }

    func submitNegativeFeedback(for message: ChatMessage, reason: FeedbackReason, customText: String?) async {
        guard let requestId = message.requestId else { return }
        let reasonText = reason == .other ? (customText ?? reason.rawValue) : reason.rawValue
        do {
            try await repo.submitFeedback(requestId: requestId, score: -1, reason: reasonText)
            if let index = chatMessages.firstIndex(where: { $0.id == message.id }) {
                chatMessages[index].feedback = -1
            }
            await repo.logAnalyticsEvent(event: "ai_feedback_sent", metadata: ["score": "-1", "reason": reason.rawValue])
        } catch {
            // Non-critical
        }
    }

    // MARK: - Navigation Actions

    /// Returns the tab index to navigate to, or nil if action is not a navigation action
    func tabIndexForAction(_ action: AssistantAction) -> Int? {
        switch action.type {
        case .openTransactions: return 1
        case .openBudgetTab: return 3
        case .openSavings: return 3
        case .openAddExpense, .openAddIncome: return nil // These open sheets
        default: return nil
        }
    }

    func handleNavigationAction(_ action: AssistantAction) -> NavigationTarget? {
        switch action.type {
        case .openTransactions:
            return .transactions(
                categoryFilter: action.payload?.category,
                merchantFilter: action.payload?.merchant,
                highlightTxIds: action.payload?.txIds
            )
        case .openBudgetTab:
            return .budgets
        case .openSavings:
            return .savings
        case .openAddExpense:
            return .addExpense
        case .openAddIncome:
            return .addIncome
        default:
            return nil
        }
    }
}

// MARK: - Navigation Target

enum NavigationTarget {
    case transactions(categoryFilter: String?, merchantFilter: String?, highlightTxIds: [String]?)
    case budgets
    case savings
    case addExpense
    case addIncome
}
