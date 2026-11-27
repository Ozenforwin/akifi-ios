#if DEBUG
import SwiftUI

/// DEBUG-only single screens for the screenshot harness (1.6 sweep:
/// Transactions, Subscriptions, Assistant, Auth, Onboarding). Compiled out
/// of Release. Fixture data only — no screen here triggers a network call.
///
/// `xcrun simctl launch <device> ru.akifi.app -AkifiUIHarness -AkifiUIHarnessScreen <name>`
/// (+ `-AkifiUIHarnessTab <tab>` for the tab under a sheet).
enum UIHarnessScreen: String, CaseIterable {
    // Auth / onboarding (signed-out roots and their sheets)
    case login, emailAuth, emailPending, forgotPassword, migration, newPassword
    case errorToast, onboarding, splash
    // Sheets over the signed-in tabs
    case invite, inviteCode, filters, subscriptionForm, categoryPicker
    case transactionDetail, homeSearch, feedback
    // Assistant with a fixture conversation (and its sheets)
    case assistantChat, actionPreview, aiConsent

    static var requested: UIHarnessScreen? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-AkifiUIHarnessScreen"),
              index + 1 < arguments.count else { return nil }
        return UIHarnessScreen(rawValue: arguments[index + 1])
    }
}

/// Root of a harness screen.
struct UIHarnessScreenView: View {
    let screen: UIHarnessScreen
    @Environment(AppViewModel.self) private var app
    @State private var sheetShown = true
    @State private var toast: String? = String(localized: "auth.error.network")

    // Filter sheet bindings
    @State private var filterAccountIds: Set<String> = []
    @State private var filterCategoryIds: Set<String> = ["demo-cat-3"]
    @State private var filterDateFrom: Date?
    @State private var filterDateTo: Date?
    @State private var filterType: TransactionTypeFilter = .expense
    @State private var categoryId: String? = "demo-cat-1"
    @State private var feedbackReason: FeedbackReason = .wrongData
    @State private var feedbackText = ""

    var body: some View {
        switch screen {
        case .login:
            LoginView()
        case .emailAuth:
            LoginView().sheet(isPresented: $sheetShown) { EmailAuthView() }
        case .emailPending:
            LoginView().sheet(isPresented: $sheetShown) { EmailPendingReplica() }
        case .forgotPassword:
            LoginView().sheet(isPresented: $sheetShown) { ForgotPasswordView() }
        case .migration:
            LoginView().sheet(isPresented: $sheetShown) { MigrationCodeView() }
        case .newPassword:
            NewPasswordView()
        case .errorToast:
            LoginView().errorToast($toast)
        case .onboarding:
            OnboardingView()
        case .splash:
            SplashView()
        case .invite:
            MainTabView().sheet(isPresented: $sheetShown) {
                AcceptInviteView(initialCode: "0123456789abcdef", kind: .budget) { _ in
                    InvitePreview(status: .pending, kind: .budget, role: "editor",
                                  inviterName: "Михаил", targetName: "Семейный бюджет",
                                  budgetHasCategoryFilter: false)
                }
            }
        case .inviteCode:
            MainTabView().sheet(isPresented: $sheetShown) {
                AcceptInviteView(previewLoader: { _ in nil })
            }
        case .filters:
            MainTabView().sheet(isPresented: $sheetShown) {
                TransactionFilterSheet(
                    accounts: app.dataStore.accounts,
                    categories: app.dataStore.displayCategories,
                    selectedAccountIds: $filterAccountIds,
                    selectedCategoryIds: $filterCategoryIds,
                    dateFrom: $filterDateFrom,
                    dateTo: $filterDateTo,
                    selectedType: $filterType
                )
                .presentationDetents([.fraction(0.75), .large])
            }
        case .subscriptionForm:
            MainTabView().sheet(isPresented: $sheetShown) {
                SubscriptionFormView { _, _, _, _, _, _, _, _, _, _ in nil }
            }
        case .categoryPicker:
            MainTabView().sheet(isPresented: $sheetShown) {
                CategoryPickerView(
                    categories: app.dataStore.categories,
                    transactionType: .expense,
                    selectedCategoryId: $categoryId
                )
                .presentationDetents([.medium, .large])
            }
        case .transactionDetail:
            MainTabView().sheet(isPresented: $sheetShown) {
                if let tx = app.dataStore.transactions.first(where: { $0.type == .expense }) {
                    TransactionDetailView(transaction: tx)
                }
            }
        case .homeSearch:
            MainTabView().sheet(isPresented: $sheetShown) { SearchView() }
        case .feedback:
            UIHarnessAssistantHost(prepare: { _ in }).sheet(isPresented: $sheetShown) {
                FeedbackSheet(reason: $feedbackReason, customText: $feedbackText, onSubmit: {}, onCancel: {})
            }
        case .assistantChat:
            UIHarnessAssistantHost(prepare: { _ in })
        case .actionPreview:
            UIHarnessAssistantHost(prepare: { vm in
                vm.pendingAction = UIHarnessAssistantFixture.budgetAction
                vm.pendingActionPreview = ActionPreview(
                    plan: "Будет создан месячный бюджет «Кафе и рестораны» на 15 000 ₽ с уведомлением при 80 %.",
                    risk: .medium,
                    changes: ["Новый бюджет: Кафе и рестораны — 15 000 ₽ в месяц", "Уведомление при 12 000 ₽"],
                    reversible: true
                )
                vm.showActionPreview = true
            })
        case .aiConsent:
            UIHarnessAssistantHost(prepare: { vm in vm.showAIConsent = true })
        }
    }
}

/// `EmailAuthView` after a sign-up that waits for the emailed link (its
/// state is private, so the same chrome is rebuilt around the component).
private struct EmailPendingReplica: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                EmailConfirmationPendingView(
                    email: "anna@example.com",
                    onResend: {},
                    onChangeEmail: {},
                    onSignIn: {}
                )
                .padding(24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(String(localized: "auth.signUp"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.close")) {}
                }
            }
        }
    }
}

// MARK: - Assistant with a fixture conversation

/// The tab bar of `MainTabView` around an `AssistantView` whose view model
/// holds a fixture conversation (the real tab owns its own view model).
private struct UIHarnessAssistantHost: View {
    @Environment(AppViewModel.self) private var app
    @State private var viewModel = AssistantViewModel()
    @State private var selection: AppTab = .assistant
    let prepare: @MainActor (AssistantViewModel) -> Void

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.barTabs, id: \.self) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    Color(.systemGroupedBackground)
                }
            }
            Tab(AppTab.assistant.title, systemImage: AppTab.assistant.systemImage, value: AppTab.assistant, role: .search) {
                AssistantView(viewModel: viewModel, showsCloseButton: false)
            }
        }
        .akifiTabBarMinimizeOnScroll()
        .tint(Color.accent)
        .onAppear {
            viewModel.dataStore = app.dataStore
            // A current conversation keeps the welcome screen from asking
            // the server for the last chat.
            viewModel.currentConversation = AiConversation(
                id: "harness-conv", userId: "demo", title: "Траты за месяц",
                source: nil, isArchived: false, createdAt: nil, updatedAt: nil
            )
            viewModel.chatMessages = UIHarnessAssistantFixture.messages
            viewModel.followUps = ["А что с транспортом?", "Сравни с прошлым годом", "Где сэкономить?"]
            prepare(viewModel)
        }
    }
}

private enum UIHarnessAssistantFixture {
    static let budgetAction = AssistantAction(
        type: .createBudgetSuggestion,
        label: "Создать бюджет «Кафе» — 15 000 ₽",
        payload: nil
    )

    static var messages: [ChatMessage] {
        var answer = ChatMessage(
            id: "m2", role: .assistant,
            content: """
            ## Траты выросли на 18 %
            Основной рост — **кафе и рестораны**: в ноябре 14 200 ₽ против обычных 10 000 ₽.

            - Чаще всего — по пятницам и субботам
            - Средний чек вырос с 820 до 1 050 ₽
            """
        )
        answer.facts = ["Кафе и рестораны: +42%", "Транспорт: без изменений"]
        answer.evidence = [
            AnomalyEvidence(type: .categorySpike, label: "Кафе и рестораны", currentValue: 14_200,
                            baselineValue: 10_000, deltaPercent: 42, txRefs: nil, heatmap: nil),
            AnomalyEvidence(type: .frequencySpike, label: "Покупки в кафе", currentValue: 13,
                            baselineValue: 8, deltaPercent: 62, txRefs: nil,
                            heatmap: (0..<7).map { HeatmapEntry(day: $0, count: [1, 1, 2, 1, 4, 3, 1][$0]) })
        ]
        answer.confidence = 0.86
        answer.recommendedActions = [
            RecommendedAction(id: "r1", label: "Показать операции", actionType: .openTransactions, payload: nil),
            RecommendedAction(id: "r2", label: "Открыть бюджеты", actionType: .openBudgetTab, payload: nil)
        ]
        answer.requestId = "req-1"
        answer.messageId = "m2"

        var proposal = ChatMessage(
            id: "m4", role: .assistant,
            content: "Могу создать бюджет на кафе, чтобы держать траты в рамках."
        )
        proposal.actions = [budgetAction]
        proposal.requestId = "req-2"
        proposal.messageId = "m4"
        proposal.feedback = 1

        return [
            ChatMessage(id: "m1", role: .user, content: "Почему в этом месяце я потратил больше?"),
            answer,
            ChatMessage(id: "m3", role: .user, content: "Что можно сделать?"),
            proposal
        ]
    }
}
#endif
