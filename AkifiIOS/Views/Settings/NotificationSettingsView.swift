import SwiftUI

struct NotificationSettingsView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @AppStorage("notif_enabled") private var enabled = true
    @AppStorage("notif_budgetWarnings") private var budgetWarnings = true
    @AppStorage("notif_budgetPercent") private var budgetPercent = 80.0
    @AppStorage("notif_weeklyPace") private var weeklyPace = false
    @AppStorage("notif_largeExpenses") private var largeExpenses = true
    @AppStorage("notif_largeThreshold") private var largeThreshold = 0 // 0 = auto
    @AppStorage("notif_inactivity") private var inactivity = false
    @AppStorage("notif_savingsMilestones") private var savingsMilestones = true

    private let thresholdOptions: [(label: String, value: Int)] = [
        ("Auto", 0),
        ("5 000", 5000),
        ("10 000", 10000),
        ("20 000", 20000),
    ]

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "notifications.enabled"), isOn: $enabled)
            } footer: {
                Text(String(localized: "notifications.enabledFooter"))
            }

            if enabled {
                Section(String(localized: "notifications.budgets")) {
                    Toggle(String(localized: "notifications.budgetWarnings"), isOn: $budgetWarnings)
                    if budgetWarnings {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "notifications.thresholdLabel") + " \(Int(budgetPercent))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: $budgetPercent, in: 50...100, step: 5)
                                .tint(.orange)
                        }
                    }
                    Toggle(String(localized: "notifications.weeklyPace"), isOn: $weeklyPace)
                }

                Section(String(localized: "notifications.expenses")) {
                    Toggle(String(localized: "notifications.largeExpenses"), isOn: $largeExpenses)
                    if largeExpenses {
                        Picker(String(localized: "notifications.largeThreshold"), selection: $largeThreshold) {
                            ForEach(thresholdOptions, id: \.value) { option in
                                Text(option.label).tag(option.value)
                            }
                        }
                        .pickerStyle(.segmented)

                        if largeThreshold == 0 {
                            Text(String(localized: "notifications.autoThresholdDesc"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle(String(localized: "notifications.inactivity"), isOn: $inactivity)
                }

                Section(String(localized: "notifications.savings")) {
                    Toggle(String(localized: "notifications.savingsMilestones"), isOn: $savingsMilestones)
                }
            }

            Color.clear.frame(height: 100)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .navigationTitle(String(localized: "settings.notifications"))
        .onChange(of: enabled) { syncToServer() }
        .onChange(of: budgetWarnings) { syncToServer() }
        .onChange(of: budgetPercent) { syncToServer() }
        .onChange(of: weeklyPace) { syncToServer() }
        .onChange(of: largeExpenses) { syncToServer() }
        .onChange(of: largeThreshold) { syncToServer() }
        .onChange(of: inactivity) { syncToServer() }
        .onChange(of: savingsMilestones) { syncToServer() }
        .task { syncToServer() }
    }

    private func syncToServer() {
        Task {
            await NotificationRepository().syncSettings(
                enabled: enabled,
                budgetWarnings: budgetWarnings,
                largeExpenses: largeExpenses,
                inactivity: inactivity,
                savingsMilestones: savingsMilestones,
                weeklyPace: weeklyPace,
                largeExpenseThreshold: largeThreshold,
                budgetWarningPercent: Int(budgetPercent)
            )
        }
    }
}
