import SwiftUI

struct AssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: AssistantViewModel
    @State private var showFeedbackSheet = false
    @State private var feedbackMessage: ChatMessage?
    @State private var feedbackReason: FeedbackReason = .notHelpful
    @State private var feedbackCustomText = ""
    @State private var showShareSheet = false

    /// The close (×) button — only when presented modally. As the Assistant
    /// tab (1.6) there is nothing to dismiss.
    var showsCloseButton = true

    /// Callback for navigation actions from the assistant
    var onNavigate: ((NavigationTarget) -> Void)?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if viewModel.chatMessages.isEmpty && !viewModel.isProcessing {
                            AssistantWelcomeView(
                                onPromptSelected: { prompt in
                                    Task { await viewModel.sendFollowUp(prompt) }
                                },
                                dataStore: viewModel.dataStore,
                                lastConversation: viewModel.lastConversationPreview,
                                onResume: {
                                    Task { await viewModel.resumeLastConversation() }
                                }
                            )
                            .padding(.top, 16)
                            .task { await viewModel.loadLastConversationPreview() }
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
                .scrollDismissesKeyboard(.interactively)
                // Bubbles and cards are content on the grouped background;
                // the composer floats over it (Messages-style, 1.6).
                .background(Color(.systemGroupedBackground))
                .akifiSafeAreaBar(edge: .bottom) { composer }
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
            .navigationTitle(String(localized: "assistant.title"))
            // A tab root gets the large title; the modal sheet stays inline.
            .navigationBarTitleDisplayMode(showsCloseButton ? .inline : .large)
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "common.close")) { dismiss() }
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
                        if viewModel.currentConversation != nil {
                            Button {
                                showShareSheet = true
                            } label: {
                                Label(String(localized: "assistant.share"), systemImage: "square.and.arrow.up")
                            }
                        }
                    } label: {
                        // The glass toolbar plate (iOS 26) already draws the circle.
                        Image(systemName: AkifiGlassRendering.current == .liquidGlass ? "ellipsis" : "ellipsis.circle")
                    }
                    .accessibilityLabel(String(localized: "assistant.chatMenu"))
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let conv = viewModel.currentConversation {
                    ShareConversationSheet(conversation: conv)
                }
            }
            .sheet(isPresented: $viewModel.showConversations) {
                ConversationListView(viewModel: viewModel)
            }
            // R8: consent before anything is sent to the AI providers.
            // Swiping the sheet away is a decline.
            .sheet(isPresented: $viewModel.showAIConsent, onDismiss: {
                viewModel.declineAIConsent()
            }) {
                AIConsentSheet(
                    onAccept: { Task { await viewModel.acceptAIConsent() } },
                    onDecline: { viewModel.declineAIConsent() }
                )
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

    /// Follow-up suggestions, the last error and the input capsule — the
    /// floating controls layer at the bottom of the chat.
    private var composer: some View {
        VStack(spacing: 8) {
            if !viewModel.followUps.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.followUps, id: \.self) { followUp in
                            Button {
                                Task { await viewModel.sendFollowUp(followUp) }
                            } label: {
                                Text(followUp)
                                    .font(.subheadline)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.akifiSecondary)
                            .buttonBorderShape(.capsule)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 2)
                }
            }

            if let error = viewModel.error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .akifiGlassBanner()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

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
        .padding(.top, 8)
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
            // Modal: close first. As a tab: the target switches tabs itself.
            if showsCloseButton { dismiss() }
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
            Form {
                Picker(selection: $reason) {
                    ForEach(FeedbackReason.allCases, id: \.self) { r in
                        Text(r.displayName).tag(r)
                    }
                } label: {
                    Text(String(localized: "feedback.whatWentWrong"))
                }
                .pickerStyle(.inline)

                if reason == .other {
                    Section {
                        TextField(String(localized: "feedback.describeProblem"), text: $customText, axis: .vertical)
                            .lineLimit(2...4)
                    }
                }
            }
            .navigationTitle(String(localized: "feedback.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.send")) { onSubmit() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Welcome

struct AssistantWelcomeView: View {
    let onPromptSelected: (String) -> Void
    var dataStore: DataStore?
    var lastConversation: ConversationPreview?
    var onResume: (() -> Void)?

    @ScaledMetric(relativeTo: .largeTitle) private var avatarSize: CGFloat = 48

    var body: some View {
        VStack(spacing: 20) {
            // The Assistant's own avatar keeps the AI gradient (1.6 rule).
            Image(systemName: "sparkles")
                .font(.system(size: avatarSize))
                .foregroundStyle(
                    LinearGradient(colors: [.aiGradientStart, .aiGradientEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(String(localized: "assistant.welcome"))
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                Text(String(localized: "assistant.welcomeSubtitle"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            if let preview = lastConversation, let onResume {
                ContinueLastChatCard(preview: preview, onTap: onResume)
            }

            QuickPromptsView(onSelect: onPromptSelected, dataStore: dataStore)
        }
    }
}

/// Surfaces the most recent unfinished chat at the top of the welcome
/// screen so the user can pick up where they left off without scrolling
/// through the conversations sheet.
struct ContinueLastChatCard: View {
    let preview: ConversationPreview
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accent)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(String(localized: "assistant.continueLast"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        if let updated = preview.conversation.updatedAt,
                           let date = ISO8601DateFormatter.shared.date(from: updated) {
                            Text(date, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let title = preview.conversation.title, !title.isEmpty {
                        Text(title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let answer = preview.lastAnswer, !answer.isEmpty {
                        Text(answer)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .akifiCard(padding: 14)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Input Bar

/// The composer: one glass capsule floating at the bottom of the chat
/// (like Messages on iOS 26) holding the text field and the send / voice
/// button; while recording it shows the timer between cancel and send.
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

    /// Half the single-line height: a capsule for one line, rounded
    /// corners once the text wraps.
    private static let cornerRadius: CGFloat = 22

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            if isRecording {
                recordingContent
            } else if isTranscribing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(String(localized: "assistant.transcribing"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                TextField(String(localized: "assistant.askSomething"), text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.leading, 16)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if hasText || isProcessing {
                    Button(action: onSend) {
                        Image(systemName: isProcessing ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accent)
                            .frame(width: 44, height: 44)
                    }
                    .disabled(!hasText && !isProcessing)
                    .accessibilityLabel(String(localized: "common.send"))
                } else {
                    Button(action: onStartRecording) {
                        Image(systemName: "mic.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(String(localized: "assistant.voiceInput"))
                }
            }
        }
        .padding(.trailing, 2)
        .frame(minHeight: 44)
        .akifiGlass(in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var recordingContent: some View {
        HStack(spacing: 8) {
            Button(action: onCancelRecording) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(String(localized: "common.cancel"))

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(formatDuration(recordingDuration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.primary)
            }
            .frame(minHeight: 44)

            Spacer()

            Button(action: onStopRecording) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accent)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(String(localized: "common.send"))
        }
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(String(localized: "common.loading"))
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
