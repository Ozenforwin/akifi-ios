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
                Text(String(localized: "ai.section.tone"))
            }

            Section {
                Toggle(String(localized: "ai.weeklyDigest"), isOn: $settings.digestOptIn)
                    .onChange(of: settings.digestOptIn) {
                        Task { await saveSettings() }
                    }
            } header: {
                Text(String(localized: "ai.section.digest"))
            } footer: {
                Text(String(localized: "ai.digestDescription"))
            }

            Section {
                Toggle(String(localized: "ai.quietHours"), isOn: $quietHoursEnabled)
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
                    Picker(String(localized: "ai.quietHours.start"), selection: Binding(
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

                    Picker(String(localized: "ai.quietHours.end"), selection: Binding(
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
                Text(String(localized: "ai.section.quietHours"))
            } footer: {
                Text(String(localized: "ai.quietHoursDescription"))
            }
        }
        .navigationTitle(String(localized: "ai.settings.title"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading {
                ProgressView()
            }
        }
        .overlay(alignment: .bottom) {
            if showSavedToast {
                Text(String(localized: "common.saved"))
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
