import SwiftUI
import PhotosUI

struct ProfileEditView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var fullName = ""
    @State private var email = ""
    @State private var avatarUrl: String?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isUploadingAvatar = false
    @State private var error: String?
    @State private var selectedPhoto: PhotosPickerItem?

    private let profileRepo = ProfileRepository()

    var body: some View {
        Form {
            // Avatar section
            Section {
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                            .frame(width: 100, height: 100)

                        if let avatarUrl, let url = URL(string: avatarUrl) {
                            CachedAsyncImage(url: url) {
                                avatarPlaceholder
                            }
                            .frame(width: 94, height: 94)
                            .clipShape(Circle())
                        } else {
                            avatarPlaceholder
                        }

                        if isUploadingAvatar {
                            Circle()
                                .fill(.ultraThinMaterial)
                                .frame(width: 94, height: 94)
                            ProgressView()
                        }
                    }

                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Text("Изменить фото")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.accent)
                    }

                    if avatarUrl != nil {
                        Button(role: .destructive) {
                            avatarUrl = nil
                        } label: {
                            Text("Удалить фото")
                                .font(.caption)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section("Личные данные") {
                TextField("Имя", text: $fullName)
                    .textContentType(.name)

                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .disabled(true)
                    .foregroundStyle(.secondary)
            }

            if appViewModel.dataStore.profile?.telegramLinkedAt != nil {
                Section("Telegram") {
                    Label("Аккаунт привязан", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
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
                .disabled(isSaving || isUploadingAvatar)
            }
        }
        .task {
            await loadProfile()
        }
        .onChange(of: selectedPhoto) {
            Task { await uploadSelectedPhoto() }
        }
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(Color(.systemGray5))
            .frame(width: 94, height: 94)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
            }
    }

    private func loadProfile() async {
        do {
            let profile = try await profileRepo.fetch()
            fullName = profile.fullName ?? ""
            email = profile.email ?? appViewModel.authManager.currentUser?.email ?? ""
            avatarUrl = profile.avatarUrl
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func uploadSelectedPhoto() async {
        guard let item = selectedPhoto else { return }
        isUploadingAvatar = true
        error = nil

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                error = "Не удалось загрузить изображение"
                isUploadingAvatar = false
                return
            }

            // Resize to max 400x400 for avatar
            guard let uiImage = UIImage(data: data) else {
                error = "Неверный формат изображения"
                isUploadingAvatar = false
                return
            }

            let resized = resizeImage(uiImage, maxSize: 400)
            guard let jpegData = resized.jpegData(compressionQuality: 0.8) else {
                error = "Ошибка сжатия изображения"
                isUploadingAvatar = false
                return
            }

            // Upload to Supabase Storage
            let userId = try await SupabaseManager.shared.client.auth.session.user.id.uuidString
            let fileName = "avatars/\(userId).jpg"

            try await SupabaseManager.shared.client.storage
                .from("avatars")
                .upload(
                    fileName,
                    data: jpegData,
                    options: .init(contentType: "image/jpeg", upsert: true)
                )

            // Get public URL
            let publicURL = try SupabaseManager.shared.client.storage
                .from("avatars")
                .getPublicURL(path: fileName)

            // Add cache-busting parameter
            avatarUrl = publicURL.absoluteString + "?t=\(Int(Date().timeIntervalSince1970))"
        } catch {
            self.error = "Ошибка загрузки: \(error.localizedDescription)"
        }

        isUploadingAvatar = false
        selectedPhoto = nil
    }

    private func resizeImage(_ image: UIImage, maxSize: CGFloat) -> UIImage {
        let size = image.size
        let ratio = min(maxSize / size.width, maxSize / size.height)
        guard ratio < 1 else { return image }
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }

    private func save() async {
        isSaving = true
        error = nil
        do {
            try await profileRepo.update(fullName: fullName, avatarUrl: avatarUrl)
            // Refresh profile in DataStore
            await appViewModel.dataStore.loadAll()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isSaving = false
    }
}
