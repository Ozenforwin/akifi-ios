import SwiftUI

struct NotificationSettingsView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var settings = NotificationSettings(
        enabled: true,
        budgetWarnings: true,
        largeExpenses: true,
        inactivity: false,
        savingsMilestones: true,
        weeklyPace: false,
        largeExpenseThreshold: 500_00,
        budgetWarningPercent: 0.8
    )
    @State private var isLoading = true

    var body: some View {
        Form {
            Section {
                Toggle("Уведомления", isOn: $settings.enabled)
            }

            if settings.enabled {
                Section("Бюджеты") {
                    Toggle("Предупреждения о бюджете", isOn: $settings.budgetWarnings)
                    if settings.budgetWarnings {
                        VStack(alignment: .leading) {
                            Text("Порог: \(Int((settings.budgetWarningPercent ?? 0.8) * 100))%")
                                .font(.caption)
                            Slider(
                                value: Binding(
                                    get: { settings.budgetWarningPercent ?? 0.8 },
                                    set: { settings.budgetWarningPercent = $0 }
                                ),
                                in: 0.5...1.0, step: 0.05
                            )
                            .tint(.orange)
                        }
                    }
                    Toggle("Еженедельный темп", isOn: $settings.weeklyPace)
                }

                Section("Расходы") {
                    Toggle("Крупные расходы", isOn: $settings.largeExpenses)
                    if settings.largeExpenses {
                        HStack {
                            Text("Порог")
                            Spacer()
                            let threshold = settings.largeExpenseThreshold ?? 500_00
                            Text(appViewModel.currencyManager.formatAmount(threshold.displayAmount))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Неактивность (>3 дня)", isOn: $settings.inactivity)
                }

                Section("Накопления") {
                    Toggle("Достижение целей", isOn: $settings.savingsMilestones)
                }
            }
        }
        .navigationTitle("Уведомления")
    }
}
