import SwiftUI

struct MessageBubbleView: View {
    let message: ChatMessage
    var onAction: ((AssistantAction) -> Void)?
    var onRecommendedAction: ((RecommendedAction) -> Void)?
    var onThumbsUp: (() -> Void)?
    var onThumbsDown: (() -> Void)?

    @State private var selectedBudgetIndices: Set<Int> = []
    @State private var budgetIndicesInitialized = false

    private var isUser: Bool { message.role == .user }
    private var isSmartBudget: Bool {
        message.actions?.contains { $0.type == .smartBudgetCreate } == true
    }

    /// Facts that represent budget line items (contain "→")
    private var budgetFacts: [(index: Int, text: String)] {
        guard let facts = message.facts else { return [] }
        return facts.enumerated().compactMap { idx, fact in
            fact.contains("→") ? (idx, fact) : nil
        }
    }

    var body: some View {
        HStack(alignment: .top) {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                // Message text
                Text(message.content)
                    .font(.subheadline)
                    .foregroundStyle(isUser ? .white : .primary)
                    .textSelection(.enabled)

                // Facts
                if let facts = message.facts, !facts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                            if isSmartBudget && fact.contains("→") {
                                // Checkbox for budget items
                                Button {
                                    if selectedBudgetIndices.contains(index) {
                                        selectedBudgetIndices.remove(index)
                                    } else {
                                        selectedBudgetIndices.insert(index)
                                    }
                                } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: selectedBudgetIndices.contains(index) ? "checkmark.square.fill" : "square")
                                            .font(.system(size: 16))
                                            .foregroundStyle(selectedBudgetIndices.contains(index) ? Color.accent : .secondary)
                                        Text(fact)
                                            .font(.caption)
                                            .foregroundStyle(selectedBudgetIndices.contains(index) ? .primary : .secondary)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
                                .buttonStyle(.plain)
                            } else {
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(fact)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                    .onAppear {
                        if isSmartBudget && !budgetIndicesInitialized {
                            selectedBudgetIndices = Set(budgetFacts.map(\.index))
                            budgetIndicesInitialized = true
                        }
                    }
                }

                // Evidence
                if let evidence = message.evidence, !evidence.isEmpty {
                    EvidenceListView(evidence: evidence, confidence: message.confidence)
                        .padding(.top, 4)
                }

                // Explainability
                if let explainability = message.explainability, !explainability.isEmpty {
                    Text(explainability)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                        .padding(.top, 2)
                }

                // Actions (execution actions)
                if let actions = message.actions?.filter({ $0.type.isExecutionAction }), !actions.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(actions) { action in
                            Button {
                                if action.type == .smartBudgetCreate {
                                    // Pass selected indices via modified action
                                    var modified = action
                                    // Store selected budget indices in payload for the action handler
                                    onAction?(modified)
                                } else {
                                    onAction?(action)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "play.circle.fill")
                                        .font(.caption)
                                    if action.type == .smartBudgetCreate {
                                        let count = selectedBudgetIndices.count
                                        Text("Создать \(count) бюджет\(budgetSuffix(count))")
                                            .font(.caption.weight(.medium))
                                    } else {
                                        Text(action.label)
                                            .font(.caption.weight(.medium))
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.accent.opacity(0.12))
                                .foregroundStyle(Color.accent)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(action.type == .smartBudgetCreate && selectedBudgetIndices.isEmpty)
                        }
                    }
                    .padding(.top, 4)
                }

                // Navigation actions (recommended)
                if let recommended = message.recommendedActions, !recommended.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(recommended) { rec in
                                Button {
                                    onRecommendedAction?(rec)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.right.circle")
                                            .font(.system(size: 10))
                                        Text(rec.label)
                                            .font(.caption)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color(.tertiarySystemBackground))
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.top, 4)
                }

                // Action result
                if let result = message.actionResult {
                    HStack(spacing: 6) {
                        Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.success ? .green : .red)
                        Text(result.message)
                            .font(.caption)
                            .foregroundStyle(result.success ? .green : .red)
                    }
                    .padding(.top, 4)
                }

                // Feedback buttons (only for assistant messages)
                if !isUser, message.requestId != nil {
                    feedbackRow
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                if isUser {
                    RoundedRectangle(cornerRadius: 18).fill(Color.accent.gradient)
                } else {
                    RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground))
                }
            }

            if !isUser { Spacer(minLength: 60) }
        }
    }

    private func budgetSuffix(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        if mod100 >= 11 && mod100 <= 19 { return "ов" }
        if mod10 == 1 { return "" }
        if mod10 >= 2 && mod10 <= 4 { return "а" }
        return "ов"
    }

    @ViewBuilder
    private var feedbackRow: some View {
        if let feedback = message.feedback {
            HStack(spacing: 4) {
                Image(systemName: feedback > 0 ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Спасибо за отзыв")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 12) {
                Button {
                    onThumbsUp?()
                } label: {
                    Image(systemName: "hand.thumbsup")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    onThumbsDown?()
                } label: {
                    Image(systemName: "hand.thumbsdown")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
