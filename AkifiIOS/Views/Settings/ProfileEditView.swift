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
    @ScaledMetric(relativeTo: .largeTitle) private var avatarSize: CGFloat = 96

    private let profileRepo = ProfileRepository()

    var body: some View {
        Form {
            // Avatar section
            Section {
                VStack(spacing: 12) {
                    ZStack {
                        if let avatarUrl, let url = URL(string: avatarUrl) {
                            CachedAsyncImage(url: url) {
                                avatarPlaceholder
                            }
                        } else {
                            avatarPlaceholder
                        }

                        if isUploadingAvatar {
                            Color.black.opacity(0.35)
                            ProgressView()
                                .tint(.white)
                        }
                    }
                    .frame(width: avatarSize, height: avatarSize)
                    .clipShape(Circle())

                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Text(String(localized: "profile.changePhoto"))
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderless)

                    if avatarUrl != nil {
                        Button(String(localized: "profile.deletePhoto"), role: .destructive) {
                            avatarUrl = nil
                        }
                        .font(.subheadline)
                        .buttonStyle(.borderless)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section(String(localized: "profile.personalData")) {
                TextField(String(localized: "profile.name"), text: $fullName)
                    .textContentType(.name)

                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .disabled(true)
                    .foregroundStyle(.secondary)
            }

            if appViewModel.dataStore.profile?.telegramLinkedAt != nil {
                Section("Telegram") {
                    Label(String(localized: "profile.telegramLinked"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if let error {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .akifiFloatingButtonClearance()
        .navigationTitle(String(localized: "settings.profile"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "common.save")) {
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
        Image(systemName: "person.crop.circle.fill")
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
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
                error = String(localized: "profile.error.loadImage")
                isUploadingAvatar = false
                return
            }

            // Resize to max 400x400 for avatar
            guard let uiImage = UIImage(data: data) else {
                error = String(localized: "profile.error.invalidFormat")
                isUploadingAvatar = false
                return
            }

            let resized = uiImage.downscaled(toMaxEdge: 400)
            guard let jpegData = resized.jpegData(compressionQuality: 0.8) else {
                error = String(localized: "profile.error.compression")
                isUploadingAvatar = false
                return
            }

            // Upload to Supabase Storage
            let userId = try await SupabaseManager.shared.currentUserId()
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
            self.error = "\(String(localized: "profile.error.upload")): \(error.localizedDescription)"
        }

        isUploadingAvatar = false
        selectedPhoto = nil
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
