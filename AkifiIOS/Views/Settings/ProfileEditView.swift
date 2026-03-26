import SwiftUI

struct ProfileEditView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var fullName = ""
    @State private var email = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?

    private let profileRepo = ProfileRepository()

    var body: some View {
        Form {
            Section("Личные данные") {
                TextField("Имя", text: $fullName)
                    .textContentType(.name)

                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .disabled(true)
                    .foregroundStyle(.secondary)
            }

            if appViewModel.authManager.currentUser?.email != nil {
                Section("Telegram") {
                    Label("Привязка через миграцию", systemImage: "paperplane")
                        .foregroundStyle(.secondary)
                }
            }

            if let error {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Профиль")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Сохранить") {
                    Task { await save() }
                }
                .disabled(isSaving)
            }
        }
        .task {
            await loadProfile()
        }
    }

    private func loadProfile() async {
        do {
            let profile = try await profileRepo.fetch()
            fullName = profile.fullName ?? ""
            email = profile.email ?? appViewModel.authManager.currentUser?.email ?? ""
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        isSaving = true
        error = nil
        do {
            try await profileRepo.update(fullName: fullName, avatarUrl: nil)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isSaving = false
    }
}
