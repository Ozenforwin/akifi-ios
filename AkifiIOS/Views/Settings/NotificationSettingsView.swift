import SwiftUI

/// The screen's state (N5): the server row first, written back only when the
/// user changes something, debounced, and kept per user — never per device.
@Observable @MainActor
final class NotificationSettingsViewModel {
    private(set) var settings: NotificationSettings = .defaults
    /// The server answered (with a row or with "none yet").
    private(set) var isLoaded = false
    /// Something to show before the server answers: this user's last known
    /// settings on this device.
    private(set) var hasLocalValue = false

    struct Remote {
        var userId: @MainActor () async -> String?
        var fetch: @MainActor () async throws -> NotificationSettings?
        var save: @MainActor (NotificationSettings) async throws -> Void
        var createIfMissing: @MainActor (NotificationSettings) async throws -> Void

        static var live: Remote {
            Remote(
                userId: { try? await SupabaseManager.shared.currentUserId() },
                fetch: { try await NotificationRepository().fetchSettings() },
                save: { try await NotificationRepository().saveSettings($0) },
                createIfMissing: { try await NotificationRepository().createSettingsIfMissing($0) }
            )
        }
    }

    @ObservationIgnored private let remote: Remote
    @ObservationIgnored private let defaults: UserDefaults
    /// Slider drags and quick toggles collapse into one write of the final
    /// value (80 → 50 used to send six unordered upserts).
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var userId: String?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var saveChain: Task<Void, Never>?

    init(remote: Remote = .live, defaults: UserDefaults = .standard, debounce: Duration = .milliseconds(600)) {
        self.remote = remote
        self.defaults = defaults
        self.debounce = debounce
    }

    /// Opening the screen reads; it never writes the device's idea of the
    /// settings over the server's.
    func load() async {
        guard let uid = await remote.userId() else { return }
        userId = uid
        if !isLoaded, let cached = NotificationPreferencesCache.settings(userId: uid, defaults: defaults) {
            settings = cached
            hasLocalValue = true
        }
        do {
            if let row = try await remote.fetch() {
                // A change the user made while the fetch ran wins.
                if pendingSave == nil { settings = row }
            } else if pendingSave == nil {
                // No row yet: the server sends nothing to users without
                // one, so store the defaults the screen shows — insert-only.
                settings = .defaults
                try? await remote.createIfMissing(.defaults)
            }
            isLoaded = true
            NotificationPreferencesCache.store(settings, userId: uid, defaults: defaults)
        } catch {
            // Offline: show the last known value, write nothing.
            AppLogger.notifications.info("Notification settings fetch failed: \(error.localizedDescription)")
        }
    }

    /// A user change: shown and cached at once, saved after the debounce.
    func update(_ change: (inout NotificationSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        if let userId { NotificationPreferencesCache.store(next, userId: userId, defaults: defaults) }
        if !next.enabled { NotificationManager.cancelWeeklyDigest() }
        scheduleSave()
    }

    /// Waits for the pending write (tests, leaving the screen).
    func flush() async {
        if let pendingSave {
            pendingSave.cancel()
            self.pendingSave = nil
            enqueueSave()
        }
        await saveChain?.value
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let debounce = self.debounce
        pendingSave = Task { @MainActor [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            self.pendingSave = nil
            self.enqueueSave()
        }
    }

    /// Writes run one after another, each with the value current when it
    /// starts — never out of order.
    private func enqueueSave() {
        let previous = saveChain
        saveChain = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try await self.remote.save(self.settings)
            } catch {
                AppLogger.notifications.info("Notification settings save failed: \(error.localizedDescription)")
            }
        }
    }

    func binding<T>(_ keyPath: WritableKeyPath<NotificationSettings, T>) -> Binding<T> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in self.update { $0[keyPath: keyPath] = value } }
        )
    }
}

struct NotificationSettingsView: View {
    @State private var model = NotificationSettingsViewModel()
    @AppStorage("subscriptionsAutoMatchEnabled") private var subscriptionsAutoMatch = true

    private let thresholdOptions: [(label: String, value: Int)] = [
        ("Auto", 0),
        ("5 000", 5000),
        ("10 000", 10000),
        ("20 000", 20000),
    ]

    var body: some View {
        let settings = model.settings
        Form {
            if !model.isLoaded && !model.hasLocalValue {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }

            Section {
                Toggle(String(localized: "notifications.enabled"), isOn: model.binding(\.enabled))
            } footer: {
                Text(String(localized: "notifications.enabledFooter"))
            }

            if settings.enabled {
                Section(String(localized: "notifications.budgets")) {
                    Toggle(String(localized: "notifications.budgetWarnings"), isOn: model.binding(\.budgetWarnings))
                    if settings.budgetWarnings {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "notifications.thresholdLabel") + " \(settings.budgetWarningPercent)%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(
                                value: Binding(
                                    get: { Double(model.settings.budgetWarningPercent) },
                                    set: { value in model.update { $0.budgetWarningPercent = Int(value.rounded()) } }
                                ),
                                in: 50...100,
                                step: 5
                            )
                            .tint(.orange)
                        }
                    }
                    Toggle(String(localized: "notifications.weeklyPace"), isOn: model.binding(\.weeklyPace))
                }

                Section(String(localized: "notifications.expenses")) {
                    Toggle(String(localized: "notifications.largeExpenses"), isOn: model.binding(\.largeExpenses))
                    if settings.largeExpenses {
                        Picker(String(localized: "notifications.largeThreshold"), selection: model.binding(\.largeExpenseThreshold)) {
                            ForEach(thresholdOptions, id: \.value) { option in
                                Text(option.label).tag(option.value)
                            }
                        }
                        .pickerStyle(.segmented)

                        if settings.largeExpenseThreshold == 0 {
                            Text(String(localized: "notifications.autoThresholdDesc"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle(String(localized: "notifications.inactivity"), isOn: model.binding(\.inactivity))
                }

                Section(String(localized: "notifications.savings")) {
                    Toggle(String(localized: "notifications.savingsMilestones"), isOn: model.binding(\.savingsMilestones))
                }

                Section {
                    Toggle(String(localized: "subscriptions.autoMatch.setting"), isOn: $subscriptionsAutoMatch)
                } header: {
                    Text(String(localized: "subscriptions.title"))
                } footer: {
                    Text(String(localized: "subscriptions.autoMatch.settingFooter"))
                }
            }

            Color.clear.frame(height: 100)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .disabled(!model.isLoaded && !model.hasLocalValue)
        .navigationTitle(String(localized: "settings.notifications"))
        .task { await model.load() }
        .onDisappear {
            let model = self.model
            Task { await model.flush() }
        }
    }
}
