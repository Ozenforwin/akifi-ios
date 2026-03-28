import SwiftUI

struct AssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: AssistantViewModel
    @State private var showFeedbackSheet = false
    @State private var feedbackMessage: ChatMessage?
    @State private var feedbackReason: FeedbackReason = .notHelpful
    @State private var feedbackCustomText = ""

    /// Callback for navigation actions from the assistant
    var onNavigate: ((NavigationTarget) -> Void)?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            if viewModel.chatMessages.isEmpty && !viewModel.isProcessing {
                                AssistantWelcomeView { prompt in
                                    Task { await viewModel.sendFollowUp(prompt) }
                                }
                                .padding(.top, 40)
                            }

                            ForEach(viewModel.chatMessages) { message in
                                MessageBubbleView(
                                    message: message,
                                    onAction: { action in
                                        Task {
                                            await viewModel.requestActionPreview(action, messageId: message.messageId)
                                        }
                                    },
                                    onRecommendedAction: { rec in
                                        handleRecommendedAction(rec)
                                    },
                                    onThumbsUp: {
                                        Task { await viewModel.submitPositiveFeedback(for: message) }
                                    },
                                    onThumbsDown: {
                                        feedbackMessage = message
                                        feedbackReason = .notHelpful
                                        feedbackCustomText = ""
                                        showFeedbackSheet = true
                                    }
                                )
                                .id(message.id)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity
                                ))
                            }

                            if viewModel.isProcessing {
                                HStack {
                                    TypingIndicatorView()
                                    Spacer()
                                }
                                .id("typing")
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: viewModel.chatMessages.count) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            if let last = viewModel.chatMessages.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: viewModel.isProcessing) {
                        if viewModel.isProcessing {
                            withAnimation {
                                proxy.scrollTo("typing", anchor: .bottom)
                            }
                        }
                    }
                }

                // Follow-ups
                if !viewModel.followUps.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(viewModel.followUps, id: \.self) { followUp in
                                Button {
                                    Task { await viewModel.sendFollowUp(followUp) }
                                } label: {
                                    Text(followUp)
                                        .font(.caption)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color(.systemBackground))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                    }
                }

                // Error
                if let error = viewModel.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                        .transition(.move(edge: .bottom))
                }

                // Input
                AssistantInputBar(
                    text: $viewModel.inputText,
                    isProcessing: viewModel.isProcessing,
                    isRecording: viewModel.isRecording,
                    isTranscribing: viewModel.isTranscribing,
                    recordingDuration: viewModel.recordingDuration,
                    onSend: { Task { await viewModel.send() } },
                    onStartRecording: { viewModel.startRecording() },
                    onStopRecording: { Task { await viewModel.stopRecordingAndSend() } },
                    onCancelRecording: { viewModel.cancelRecording() }
                )
            }
            .navigationTitle(String(localized: "assistant.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await viewModel.startNewConversation() }
                        } label: {
                            Label(String(localized: "assistant.newChat"), systemImage: "plus.message")
                        }
                        Button {
                            viewModel.showConversations = true
                        } label: {
                            Label(String(localized: "assistant.history"), systemImage: "clock")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $viewModel.showConversations) {
                ConversationListView(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showActionPreview) {
                if let action = viewModel.pendingAction,
                   let preview = viewModel.pendingActionPreview {
                    ActionPreviewSheet(
                        action: action,
                        preview: preview,
                        isProcessing: viewModel.actionProcessing,
                        onConfirm: {
                            Task { await viewModel.confirmAction() }
                        },
                        onCancel: {
                            viewModel.cancelAction()
                        }
                    )
                }
            }
            .sheet(isPresented: $showFeedbackSheet) {
                FeedbackSheet(
                    reason: $feedbackReason,
                    customText: $feedbackCustomText,
                    onSubmit: {
                        if let message = feedbackMessage {
                            Task {
                                await viewModel.submitNegativeFeedback(
                                    for: message,
                                    reason: feedbackReason,
                                    customText: feedbackReason == .other ? feedbackCustomText : nil
                                )
                            }
                        }
                        showFeedbackSheet = false
                    },
                    onCancel: {
                        showFeedbackSheet = false
                    }
                )
            }
        }
    }

    private func handleRecommendedAction(_ rec: RecommendedAction) {
        let action = AssistantAction(
            type: AssistantActionType(rawValue: rec.actionType.rawValue) ?? .openTransactions,
            label: rec.label,
            payload: rec.payload.map {
                ActionPayload(
                    txIds: $0.txIds, category: $0.category,
                    merchant: $0.merchant, minAmount: $0.minAmount,
                    amount: nil, type: nil, categoryId: nil,
                    accountId: nil, description: nil, date: nil,
                    budgetId: nil, categoryIds: nil, accountIds: nil,
                    periodType: nil, budgetType: nil,
                    goalId: nil, goalName: nil, targetAmount: nil
                )
            }
        )
        if let target = viewModel.handleNavigationAction(action) {
            dismiss()
            onNavigate?(target)
        }
    }
}

// MARK: - Feedback Sheet

struct FeedbackSheet: View {
    @Binding var reason: FeedbackReason
    @Binding var customText: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(String(localized: "feedback.whatWentWrong"))
                    .font(.headline)

                ForEach(FeedbackReason.allCases, id: \.self) { r in
                    Button {
                        reason = r
                    } label: {
                        HStack {
                            Text(r.displayName)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Spacer()
                            if reason == r {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accent)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }

                if reason == .other {
                    TextField(String(localized: "feedback.describeProblem"), text: $customText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...4)
                        .padding(12)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Spacer()

                Button {
                    onSubmit()
                } label: {
                    Text(String(localized: "common.send"))
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding()
            .navigationTitle(String(localized: "feedback.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) { onCancel() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Welcome

struct AssistantWelcomeView: View {
    let onPromptSelected: (String) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(colors: [.aiGradientStart, .aiGradientEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
                )

            Text(String(localized: "assistant.welcome"))
                .font(.title2.weight(.bold))

            Text(String(localized: "assistant.welcomeSubtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            QuickPromptsView(onSelect: onPromptSelected)
        }
    }
}

struct SuggestionChip: View {
    let text: String

    var body: some View {
        HStack {
            Image(systemName: "sparkle")
                .font(.caption)
                .foregroundStyle(Color.accent)
            Text(text)
                .font(.subheadline)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .clipShape(Capsule())
    }
}

// MARK: - Input Bar

struct AssistantInputBar: View {
    @Binding var text: String
    let isProcessing: Bool
    let isRecording: Bool
    let isTranscribing: Bool
    let recordingDuration: TimeInterval
    let onSend: () -> Void
    let onStartRecording: () -> Void
    let onStopRecording: () -> Void
    let onCancelRecording: () -> Void

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if isRecording {
                // Recording mode
                HStack(spacing: 16) {
                    Button(action: onCancelRecording) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                    }

                    Spacer()

                    HStack(spacing: 6) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text(formatDuration(recordingDuration))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.primary)
                    }

                    Spacer()

                    Button(action: onStopRecording) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.aiGradientStart, .aiGradientEnd],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            } else if isTranscribing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(String(localized: "assistant.transcribing"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                // Normal mode
                HStack(spacing: 8) {
                    TextField(String(localized: "assistant.askSomething"), text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 20))

                    if hasText || isProcessing {
                        Button(action: onSend) {
                            Image(systemName: isProcessing ? "stop.circle.fill" : "arrow.up.circle.fill")
                                .font(.title2)
                                .foregroundStyle(Color.accent)
                        }
                        .disabled(!hasText && !isProcessing)
                    } else {
                        Button(action: onStartRecording) {
                            Image(systemName: "mic.circle.fill")
                                .font(.title2)
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [.aiGradientStart, .aiGradientEnd],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        }
                        .accessibilityLabel(String(localized: "assistant.voiceInput"))
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
        .background(.bar)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Typing Indicator

struct TypingIndicatorView: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
                    .scaleEffect(animating ? 1.0 : 0.5)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever()
                            .delay(Double(index) * 0.2),
                        value: animating
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .onAppear { animating = true }
    }
}

// MARK: - Conversation List

struct ConversationListView: View {
    let viewModel: AssistantViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if viewModel.conversations.isEmpty {
                    ContentUnavailableView(String(localized: "assistant.noConversations"), systemImage: "bubble.left.and.bubble.right")
                } else {
                    ForEach(viewModel.conversations) { conversation in
                        Button {
                            Task {
                                await viewModel.selectConversation(conversation)
                                dismiss()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(conversation.title ?? String(localized: "assistant.newConversation"))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                if let date = conversation.updatedAt ?? conversation.createdAt {
                                    Text(date.prefix(10))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await viewModel.archiveConversation(conversation) }
                            } label: {
                                Label(String(localized: "common.archive"), systemImage: "archivebox")
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "assistant.history"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.close")) { dismiss() }
                }
            }
            .task {
                await viewModel.loadConversations()
            }
        }
    }
}
