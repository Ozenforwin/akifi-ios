import Foundation

@Observable @MainActor
final class AssistantViewModel {
    var conversations: [AiConversation] = []
    var currentConversation: AiConversation?
    var messages: [AiMessage] = []
    var inputText = ""
    var isProcessing = false
    var error: String?
    var followUps: [String] = []
    var showConversations = false

    private let repo = AiRepository()

    func loadConversations() async {
        do {
            conversations = try await repo.fetchConversations()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func startNewConversation() async {
        do {
            let conv = try await repo.createConversation()
            currentConversation = conv
            conversations.insert(conv, at: 0)
            messages = []
            followUps = []
        } catch {
            self.error = error.localizedDescription
        }
    }

    func selectConversation(_ conversation: AiConversation) async {
        currentConversation = conversation
        do {
            messages = try await repo.fetchMessages(conversationId: conversation.id)
            followUps = []
        } catch {
            self.error = error.localizedDescription
        }
    }

    func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""

        // Ensure conversation exists
        if currentConversation == nil {
            await startNewConversation()
        }
        guard let conversationId = currentConversation?.id else { return }

        // Add user message optimistically
        let userMessage = AiMessage(
            id: UUID().uuidString,
            conversationId: conversationId,
            userId: "",
            role: .user,
            content: text,
            intent: nil,
            period: nil,
            createdAt: nil
        )
        messages.append(userMessage)

        isProcessing = true
        error = nil

        do {
            let response: AssistantResponse = try await repo.sendMessage(
                conversationId: conversationId,
                content: text
            )

            let assistantMessage = AiMessage(
                id: UUID().uuidString,
                conversationId: conversationId,
                userId: "",
                role: .assistant,
                content: response.reply,
                intent: response.intent,
                period: nil,
                createdAt: nil
            )
            messages.append(assistantMessage)
            followUps = response.followUps ?? []
        } catch {
            self.error = "Не удалось получить ответ"
        }

        isProcessing = false
    }

    func sendFollowUp(_ text: String) async {
        inputText = text
        await send()
    }

    func archiveConversation(_ conversation: AiConversation) async {
        do {
            try await repo.archiveConversation(id: conversation.id)
            conversations.removeAll { $0.id == conversation.id }
            if currentConversation?.id == conversation.id {
                currentConversation = nil
                messages = []
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
