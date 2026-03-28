import SwiftUI

struct MessageBubbleView: View {
    let message: ChatMessage
    var onAction: ((AssistantAction) -> Void)?
    var onRecommendedAction: ((RecommendedAction) -> Void)?
    var onThumbsUp: (() -> Void)?
    var onThumbsDown: (() -> Void)?

    private var isUser: Bool { message.role == .user }

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
                        ForEach(facts, id: \.self) { fact in
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
                    .padding(.top, 4)
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
                                onAction?(action)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "play.circle.fill")
                                        .font(.caption)
                                    Text(action.label)
                                        .font(.caption.weight(.medium))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.accent.opacity(0.12))
                                .foregroundStyle(Color.accent)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
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
