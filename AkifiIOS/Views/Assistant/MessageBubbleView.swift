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

    private var budgetFacts: [(index: Int, text: String)] {
        guard let facts = message.facts else { return [] }
        return facts.enumerated().compactMap { idx, fact in
            fact.contains("→") ? (idx, fact) : nil
        }
    }

    var body: some View {
        if isUser {
            userBubble
        } else {
            assistantBubble
        }
    }

    // MARK: - User Bubble

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 80)
            Text(message.content)
                .font(.body)
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.accent.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 20))
        }
    }

    // MARK: - Assistant Bubble

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main text — full width, readable size
            Group {
                if let md = try? AttributedString(markdown: message.content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                    Text(md)
                } else {
                    Text(message.content)
                }
            }
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            // Facts
            if let facts = message.facts, !facts.isEmpty {
                factsSection(facts)
                    .padding(.top, 12)
            }

            // Evidence
            if let evidence = message.evidence, !evidence.isEmpty {
                EvidenceListView(evidence: evidence, confidence: message.confidence)
                    .padding(.top, 12)
            }

            // Explainability
            if let text = message.explainability, !text.isEmpty {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .italic()
                    .padding(.top, 8)
            }

            // Action buttons
            if let actions = message.actions?.filter({ $0.type.isExecutionAction }), !actions.isEmpty {
                actionButtons(actions)
                    .padding(.top, 12)
            }

            // Recommended navigation
            if let recommended = message.recommendedActions, !recommended.isEmpty {
                recommendedActions(recommended)
                    .padding(.top, 12)
            }

            // Action result
            if let result = message.actionResult {
                actionResultView(result)
                    .padding(.top, 8)
            }

            // Feedback
            if !isUser, message.requestId != nil {
                feedbackRow
                    .padding(.top, 10)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Facts

    @ViewBuilder
    private func factsSection(_ facts: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                if isSmartBudget && fact.contains("→") {
                    Button {
                        if selectedBudgetIndices.contains(index) {
                            selectedBudgetIndices.remove(index)
                        } else {
                            selectedBudgetIndices.insert(index)
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: selectedBudgetIndices.contains(index) ? "checkmark.square.fill" : "square")
                                .font(.system(size: 18))
                                .foregroundStyle(selectedBudgetIndices.contains(index) ? Color.accent : Color.gray)
                            Text(fact)
                                .font(.subheadline)
                                .foregroundStyle(selectedBudgetIndices.contains(index) ? .primary : .secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                        Text(fact)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .onAppear {
            if isSmartBudget && !budgetIndicesInitialized {
                selectedBudgetIndices = Set(budgetFacts.map(\.index))
                budgetIndicesInitialized = true
            }
        }
    }

    // MARK: - Action Buttons

    private func actionButtons(_ actions: [AssistantAction]) -> some View {
        VStack(spacing: 8) {
            ForEach(actions) { action in
                Button {
                    onAction?(action)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.circle.fill")
                            .font(.subheadline)
                        if action.type == .smartBudgetCreate {
                            let count = selectedBudgetIndices.count
                            Text("Создать \(count) бюджет\(budgetSuffix(count))")
                                .font(.subheadline.weight(.semibold))
                        } else {
                            Text(action.label)
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .foregroundStyle(Color.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(Color.accent.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(action.type == .smartBudgetCreate && selectedBudgetIndices.isEmpty)
            }
        }
    }

    // MARK: - Recommended Actions

    private func recommendedActions(_ recommended: [RecommendedAction]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(recommended) { rec in
                    Button {
                        onRecommendedAction?(rec)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.right.circle")
                                .font(.system(size: 12))
                            Text(rec.label)
                                .font(.subheadline)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Action Result

    private func actionResultView(_ result: ChatMessage.ActionResultState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.subheadline)
            Text(result.message)
                .font(.subheadline)
        }
        .foregroundStyle(result.success ? .green : .red)
    }

    // MARK: - Feedback

    @ViewBuilder
    private var feedbackRow: some View {
        if let feedback = message.feedback {
            HStack(spacing: 6) {
                Image(systemName: feedback > 0 ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(localized: "feedback.thanks"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 16) {
                Button { onThumbsUp?() } label: {
                    Image(systemName: "hand.thumbsup")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                Button { onThumbsDown?() } label: {
                    Image(systemName: "hand.thumbsdown")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Helpers

    private func budgetSuffix(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        if mod100 >= 11 && mod100 <= 19 { return "ов" }
        if mod10 == 1 { return "" }
        if mod10 >= 2 && mod10 <= 4 { return "а" }
        return "ов"
    }
}
