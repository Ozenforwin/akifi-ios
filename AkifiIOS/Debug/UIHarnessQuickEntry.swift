#if DEBUG
import Foundation

/// DEBUG-only quick-entry fixtures for the UI harness (`UIHarness`).
///
/// `-AkifiUIHarnessQuickEntry <state>` opens the quick-entry sheet over the
/// harness tabs through the real inbox (`QuickEntryInbox`), with a Russian
/// fixture (accounts, categories, a history the predictor learns from) and
/// an offline data store, so «Сохранить» queues locally:
///
/// | State | Sheet |
/// |---|---|
/// | `empty` | expense mode, nothing typed (the «Повторить» strip shows) |
/// | `typed` | «кофе 300» typed (Кафе preselected from the history) |
/// | `voice` | voice mode with a scripted recognizer: «такси 450» heard, still listening |
///
/// The repeat and toast screenshots: tap a «Повторить» item / «Сохранить»
/// with `idb ui tap`.
enum UIHarnessQuickEntry {
    static var state: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-AkifiUIHarnessQuickEntry"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1].lowercased()
    }

    static var isEnabled: Bool { UIHarness.isEnabled && state != nil }

    // MARK: - Fixture

    static let accounts: [Account] = [
        Account(id: "qe-acc-card", userId: "demo", name: "Тинькофф", icon: "💳", color: "#3B82F6",
                initialBalance: 84_250_00, isPrimary: true, currency: "RUB"),
        Account(id: "qe-acc-cash", userId: "demo", name: "Наличные", icon: "💵", color: "#10B981",
                initialBalance: 6_400_00, currency: "RUB", accountType: .cash),
    ]

    static let categories: [Category] = [
        category("qe-cat-cafe", "Кафе", "☕"),
        category("qe-cat-food", "Продукты", "🛒"),
        category("qe-cat-taxi", "Такси", "🚕"),
        category("qe-cat-fun", "Развлечения", "🎬"),
        category("qe-cat-health", "Здоровье", "💊"),
        category("qe-cat-clothes", "Одежда", "👕"),
        category("qe-cat-home", "Дом", "🏠"),
        category("qe-cat-salary", "Зарплата", "💰", .income),
        category("qe-cat-gift", "Подарки", "🎁", .income),
    ]

    private static func category(_ id: String, _ name: String, _ icon: String, _ type: CategoryType = .expense) -> Category {
        Category(id: id, userId: "demo", accountId: nil, name: name, icon: icon, color: "#3B82F6",
                 type: type, isActive: true, createdAt: "2026-01-01T00:00:00Z")
    }

    /// A few weeks of habits, newest first.
    static func transactions(now: Date = Date()) -> [Transaction] {
        let calendar = AppDateFormatters.localCalendar
        let hour = calendar.component(.hour, from: now)
        var rows: [Transaction] = []
        func add(_ daysAgo: Int, _ description: String, _ rubles: Int64, _ categoryId: String,
                 account: String = "qe-acc-card", type: TransactionType = .expense, hourOffset: Int = 0) {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            var components = calendar.dateComponents([.year, .month, .day], from: day)
            components.hour = min(23, max(0, hour + hourOffset))
            components.minute = 10
            let stamp = calendar.date(from: components) ?? day
            let raw = AppDateFormatters.localDateTime.string(from: stamp)
            rows.append(Transaction(
                id: "qe-tx-\(rows.count)", userId: "demo", accountId: account,
                amount: rubles * 100, amountNative: rubles * 100, currency: "RUB",
                description: description, categoryId: categoryId, type: type,
                date: String(raw.prefix(10)), rawDateTime: raw,
                merchantName: nil, merchantFuzzy: nil, transferGroupId: nil,
                status: nil, createdAt: raw, updatedAt: nil
            ))
        }
        add(0, "Кофе", 300, "qe-cat-cafe", hourOffset: -2)
        add(1, "Такси", 450, "qe-cat-taxi", hourOffset: -1)
        add(1, "Пятёрочка", 1_240, "qe-cat-food", account: "qe-acc-cash", hourOffset: 3)
        add(2, "Кофе", 300, "qe-cat-cafe")
        add(3, "Кино", 990, "qe-cat-fun", hourOffset: 5)
        add(4, "Аптека", 650, "qe-cat-health")
        add(5, "Кофе", 300, "qe-cat-cafe")
        add(6, "Такси", 520, "qe-cat-taxi", hourOffset: 2)
        add(8, "Пятёрочка", 2_310, "qe-cat-food", account: "qe-acc-cash")
        add(10, "Зарплата", 120_000, "qe-cat-salary", type: .income)
        add(12, "Кофе", 300, "qe-cat-cafe")
        add(15, "Такси", 450, "qe-cat-taxi")
        return rows
    }

    /// The fixture into `store`; the store answers offline so a save
    /// queues locally and nothing reaches the network.
    @MainActor
    static func install(in store: DataStore) {
        store.isConnectedProvider = { false }
        store.accounts = accounts
        store.categories = categories
        store.transactions = transactions()
        store.budgets = []
        store.subscriptions = []
        store.rebuildCaches()
        store.currencyContextDidChange()
    }

    /// The request the harness opens with.
    static func request() -> QuickEntryRequest? {
        switch state {
        case "empty", "repeat", "toast": QuickEntryRequest(mode: .expense, source: .link)
        case "typed": QuickEntryRequest(mode: .expense, source: .link, text: "кофе 300")
        case "voice": QuickEntryRequest(mode: .voice, source: .link)
        default: nil
        }
    }

    /// Session-free submitter and, for `voice`, the scripted recognizer.
    @MainActor
    static func configure(_ coordinator: QuickEntryCoordinator) {
        guard isEnabled else { return }
        coordinator.configureSubmitter = { submitter in
            submitter.userId = { "demo" }
            submitter.rates = { _ in ["USD": 1, "RUB": 92.5, "EUR": 0.92] }
        }
        if state == "voice" {
            coordinator.makeSpeech = {
                let speech = SpeechQuickEntry(
                    recognizer: ScriptedRecognizer(),
                    permissions: GrantedPermissions(),
                    locale: Locale(identifier: "ru-RU")
                )
                // Stay in «listening» for the screenshot.
                speech.silenceTimeout = .seconds(600)
                speech.initialSilenceTimeout = .seconds(600)
                speech.maxDuration = .seconds(600)
                return speech
            }
        }
    }

    // MARK: - Scripted speech

    @MainActor
    private final class ScriptedRecognizer: QuickEntrySpeechRecognizing {
        private var continuation: AsyncThrowingStream<QuickEntrySpeechChunk, Error>.Continuation?
        private var task: Task<Void, Never>?

        func isAvailable(locale: Locale) -> Bool { true }

        func start(locale: Locale, contextualStrings: [String]) throws -> AsyncThrowingStream<QuickEntrySpeechChunk, Error> {
            let (stream, continuation) = AsyncThrowingStream<QuickEntrySpeechChunk, Error>.makeStream()
            self.continuation = continuation
            task = Task {
                for words in ["такси", "такси 450"] {
                    try? await Task.sleep(for: .milliseconds(700))
                    continuation.yield(QuickEntrySpeechChunk(text: words, isFinal: false))
                }
            }
            return stream
        }

        func finishAudio() {
            continuation?.yield(QuickEntrySpeechChunk(text: "такси 450", isFinal: true))
            continuation?.finish()
        }

        func cancel() {
            task?.cancel()
            continuation?.finish()
        }
    }

    @MainActor
    private final class GrantedPermissions: QuickEntrySpeechPermissions {
        func speechAuthorization() -> QuickEntrySpeechAuthorization { .authorized }
        func requestSpeechAuthorization() async -> QuickEntrySpeechAuthorization { .authorized }
        func microphoneGranted() -> Bool? { true }
        func requestMicrophone() async -> Bool { true }
    }
}
#endif
