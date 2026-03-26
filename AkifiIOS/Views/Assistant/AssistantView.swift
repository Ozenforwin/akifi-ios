import SwiftUI

struct AssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = AssistantViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            if viewModel.messages.isEmpty && !viewModel.isProcessing {
                                AssistantWelcomeView()
                                    .padding(.top, 40)
                            }

                            ForEach(viewModel.messages) { message in
                                MessageBubbleView(
                                    message: message,
                                    isUser: message.role == .user
                                )
                                .id(message.id)
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
                    .onChange(of: viewModel.messages.count) {
                        withAnimation {
                            if let last = viewModel.messages.last {
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
                                        .background(.ultraThinMaterial)
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
                }

                // Input
                AssistantInputBar(
                    text: $viewModel.inputText,
                    isProcessing: viewModel.isProcessing
                ) {
                    Task { await viewModel.send() }
                }
            }
            .navigationTitle("Ассистент")
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
                            Label("Новый чат", systemImage: "plus.message")
                        }
                        Button {
                            viewModel.showConversations = true
                        } label: {
                            Label("История", systemImage: "clock")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $viewModel.showConversations) {
                ConversationListView(viewModel: viewModel)
            }
        }
    }
}

// MARK: - Welcome

struct AssistantWelcomeView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.green.gradient)

            Text("Привет! Я Akifi")
                .font(.title2.weight(.bold))

            Text("Спросите меня о ваших финансах — расходы, бюджеты, советы по экономии")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 8) {
                SuggestionChip(text: "Сколько я потратил в этом месяце?")
                SuggestionChip(text: "Покажи расходы по категориям")
                SuggestionChip(text: "Как мне сэкономить?")
            }
        }
    }
}

struct SuggestionChip: View {
    let text: String

    var body: some View {
        HStack {
            Image(systemName: "sparkle")
                .font(.caption)
                .foregroundStyle(.green)
            Text(text)
                .font(.subheadline)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }
}

// MARK: - Input Bar

struct AssistantInputBar: View {
    @Binding var text: String
    let isProcessing: Bool
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Спросите что-нибудь...", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20))

            Button(action: onSend) {
                Image(systemName: isProcessing ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isProcessing)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
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
        .background(.ultraThinMaterial)
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
                    ContentUnavailableView("Нет бесед", systemImage: "bubble.left.and.bubble.right")
                } else {
                    ForEach(viewModel.conversations) { conversation in
                        Button {
                            Task {
                                await viewModel.selectConversation(conversation)
                                dismiss()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(conversation.title ?? "Новая беседа")
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
                                Label("Архив", systemImage: "archivebox")
                            }
                        }
                    }
                }
            }
            .navigationTitle("История")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .task {
                await viewModel.loadConversations()
            }
        }
    }
}
