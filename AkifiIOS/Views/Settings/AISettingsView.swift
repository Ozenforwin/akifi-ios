import SwiftUI

struct AISettingsView: View {
    @State private var settings = AIUserSettings.default
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var showSavedToast = false
    @State private var quietHoursEnabled = false

    private let repo = AiRepository()

    var body: some View {
        Form {
            // Tone selection
            Section {
                ForEach(AITone.allCases, id: \.self) { tone in
                    Button {
                        settings.tone = tone
                        Task { await saveSettings() }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tone.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                Text(tone.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if settings.tone == tone {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Тон ответов")
            }

            // Weekly digest
            Section {
                Toggle("Еженедельный дайджест", isOn: $settings.digestOptIn)
                    .onChange(of: settings.digestOptIn) {
                        Task { await saveSettings() }
                    }
            } header: {
                Text("Дайджест")
            } footer: {
                Text("Получайте сводку по финансам каждый понедельник")
            }

            // Quiet hours
            Section {
                Toggle("Тихие часы", isOn: $quietHoursEnabled)
                    .onChange(of: quietHoursEnabled) {
                        if !quietHoursEnabled {
                            settings.quietHoursStart = nil
                            settings.quietHoursEnd = nil
                        } else {
                            settings.quietHoursStart = settings.quietHoursStart ?? 23
                            settings.quietHoursEnd = settings.quietHoursEnd ?? 8
                        }
                        Task { await saveSettings() }
                    }

                if quietHoursEnabled {
                    Picker("Начало", selection: Binding(
                        get: { settings.quietHoursStart ?? 23 },
                        set: {
                            settings.quietHoursStart = $0
                            Task { await saveSettings() }
                        }
                    )) {
                        ForEach(0..<24) { hour in
                            Text("\(hour):00").tag(hour)
                        }
                    }

                    Picker("Конец", selection: Binding(
                        get: { settings.quietHoursEnd ?? 8 },
                        set: {
                            settings.quietHoursEnd = $0
                            Task { await saveSettings() }
                        }
                    )) {
                        ForEach(0..<24) { hour in
                            Text("\(hour):00").tag(hour)
                        }
                    }
                }
            } header: {
                Text("Тихие часы")
            } footer: {
                Text("Без уведомлений AI в указанное время")
            }
        }
        .navigationTitle("Настройки AI")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading {
                ProgressView()
            }
        }
        .overlay(alignment: .bottom) {
            if showSavedToast {
                Text("Сохранено")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.green.opacity(0.9))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 20)
            }
        }
        .task { await loadSettings() }
    }

    private func loadSettings() async {
        do {
            if let loaded = try await repo.fetchSettings() {
                settings = loaded
                quietHoursEnabled = loaded.quietHoursStart != nil
            }
        } catch {
            // Use defaults
        }
        isLoading = false
    }

    private func saveSettings() async {
        isSaving = true
        do {
            try await repo.upsertSettings(settings)
            withAnimation {
                showSavedToast = true
            }
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation {
                showSavedToast = false
            }
        } catch {
            // Silent
        }
        isSaving = false
    }
}
