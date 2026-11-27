#if DEBUG
import SwiftUI
import UIKit

/// DEBUG-only single screens for the screenshot harness (1.6 sweep:
/// Transactions, Subscriptions, Assistant, Auth, Onboarding). Compiled out
/// of Release. Fixture data only — no screen here triggers a network call.
///
/// `xcrun simctl launch <device> ru.akifi.app -AkifiUIHarness -AkifiUIHarnessScreen <name>`
/// (+ `-AkifiUIHarnessTab <tab>` for the tab under a sheet). With
/// `-AkifiUIHarnessCapture <dir> -AkifiUIHarnessPlan name@look,…` the app
/// steps through the plan itself and writes a window snapshot per step
/// (`UIHarnessCaptureRoot`) — no `simctl` round trip per screenshot.
enum UIHarnessScreen: String, CaseIterable {
    // Auth / onboarding (signed-out roots and their sheets)
    case login, emailAuth, emailPending, forgotPassword, migration, newPassword
    case errorToast, onboarding, splash
    case onboardingCurrency, onboardingAccount, onboardingFeatures, onboardingNotifications, onboardingDone
    // Tab roots
    case tabTransactions, tabAssistant
    // Sheets over the signed-in tabs
    case invite, inviteCode, filters, subscriptionForm, categoryPicker
    case transactionDetail, homeSearch, feedback
    // Assistant with a fixture conversation (and its sheets)
    case assistantChat, chatEnd, actionPreview, aiConsent

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
    /// Raised a moment after the screen appears: a sheet presented while a
    /// previous one is still dismissing would be dropped.
    @State private var sheetShown = false
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

    /// The tab under the screen (sheets over the signed-in UI).
    private var baseTab: AppTab {
        switch screen {
        case .tabAssistant: .assistant
        default: .transactions
        }
    }

    /// `MainTabView` opened on `baseTab`.
    private var tabs: some View {
        MainTabView()
            .onAppear { app.pendingDeepLink = .tab(baseTab) }
    }

    var body: some View {
        content.task {
            try? await Task.sleep(for: .seconds(0.8))
            sheetShown = true
        }
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .tabTransactions, .tabAssistant:
            tabs
        case .onboardingCurrency:
            OnboardingStepReplica(step: 1)
        case .onboardingAccount:
            OnboardingStepReplica(step: 2)
        case .onboardingFeatures:
            OnboardingStepReplica(step: 3)
        case .onboardingNotifications:
            OnboardingStepReplica(step: 4)
        case .onboardingDone:
            OnboardingStepReplica(step: 5)
        case .chatEnd:
            UIHarnessAssistantHost(prepare: { _ in })
                .task {
                    try? await Task.sleep(for: .seconds(1))
                    UIHarness.scrollVisibleList(by: 10_000)
                }
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
            tabs.sheet(isPresented: $sheetShown) {
                AcceptInviteView(initialCode: "0123456789abcdef", kind: .budget) { _ in
                    InvitePreview(status: .pending, kind: .budget, role: "editor",
                                  inviterName: "Михаил", targetName: "Семейный бюджет",
                                  budgetHasCategoryFilter: false)
                }
            }
        case .inviteCode:
            tabs.sheet(isPresented: $sheetShown) {
                AcceptInviteView(previewLoader: { _ in nil })
            }
        case .filters:
            tabs.sheet(isPresented: $sheetShown) {
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
            tabs.sheet(isPresented: $sheetShown) {
                SubscriptionFormView { _, _, _, _, _, _, _, _, _, _ in nil }
            }
        case .categoryPicker:
            tabs.sheet(isPresented: $sheetShown) {
                CategoryPickerView(
                    categories: app.dataStore.categories,
                    transactionType: .expense,
                    selectedCategoryId: $categoryId
                )
                .presentationDetents([.medium, .large])
            }
        case .transactionDetail:
            tabs.sheet(isPresented: $sheetShown) {
                if let tx = app.dataStore.transactions.first(where: { $0.type == .expense }) {
                    TransactionDetailView(transaction: tx)
                }
            }
        case .homeSearch:
            tabs.sheet(isPresented: $sheetShown) { SearchView() }
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

/// One onboarding step inside the same chrome as `OnboardingView` (its
/// page index is private state; the steps themselves are the real views).
private struct OnboardingStepReplica: View {
    let step: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(0..<6) { index in
                    Circle()
                        .fill(index <= step ? Color.accent : Color(.systemFill))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 20)

            Group {
                switch step {
                case 1: CurrencyStepView {}
                case 2: AccountStepView {}
                case 3: FeaturesStepView {}
                case 4: NotificationsStepView {}
                default: CompletionStepView {}
                }
            }
            .fitsOrScrolls()
            .frame(maxHeight: .infinity)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .tint(Color.accent)
    }
}

// MARK: - In-app capture

/// Window snapshots taken by the app itself, step by step through a plan —
/// for when the simulator service is too busy for `simctl io screenshot`.
/// No status bar in these images (it isn't part of the app's window).
enum UIHarnessCapture {
    enum Look: String {
        case light, dark, xxxl

        var colorScheme: ColorScheme { self == .dark ? .dark : .light }
        var dynamicTypeSize: DynamicTypeSize { self == .xxxl ? .accessibility3 : .large }
    }

    struct Step {
        let screen: UIHarnessScreen
        let look: Look
        var fileName: String { "\(screen.rawValue)-\(look.rawValue).png" }
    }

    private static func value(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static var directory: URL? {
        value(after: "-AkifiUIHarnessCapture").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// `name@look,name@look,…` (look defaults to light).
    static var plan: [Step] {
        (value(after: "-AkifiUIHarnessPlan") ?? "")
            .split(separator: ",")
            .compactMap { item in
                let parts = item.split(separator: "@").map(String.init)
                guard let screen = parts.first.flatMap(UIHarnessScreen.init(rawValue:)) else { return nil }
                let look = parts.count > 1 ? (Look(rawValue: parts[1]) ?? .light) : .light
                return Step(screen: screen, look: look)
            }
    }

    @MainActor
    static func captureKeyWindow(to url: URL) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: url)
    }
}

/// Steps through `UIHarnessCapture.plan`: shows a screen, waits for it to
/// settle (sheets, data), snapshots the window, clears the stage, next.
struct UIHarnessCaptureRoot: View {
    let steps: [UIHarnessCapture.Step]
    let directory: URL
    @State private var index = 0
    @State private var staging = false

    var body: some View {
        Group {
            if index >= steps.count {
                Color(.systemBackground)
                    .task {
                        try? Data("done \(steps.count)\n".utf8).write(to: directory.appendingPathComponent("capture-done.txt"))
                    }
            } else if staging {
                Color(.systemBackground)
            } else {
                let step = steps[index]
                UIHarnessScreenView(screen: step.screen)
                    .id(index)
                    .preferredColorScheme(step.look.colorScheme)
                    .dynamicTypeSize(step.look.dynamicTypeSize)
                    .task(id: index) {
                        try? await Task.sleep(for: .seconds(4.5))
                        UIHarnessCapture.captureKeyWindow(to: directory.appendingPathComponent(step.fileName))
                        // An empty stage between steps lets sheets dismiss
                        // before the next screen presents its own.
                        staging = true
                        try? await Task.sleep(for: .seconds(2))
                        index += 1
                        staging = false
                    }
            }
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
        }
        .task {
            // Sheets the preparation raises come after the screen settles.
            try? await Task.sleep(for: .seconds(0.8))
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
