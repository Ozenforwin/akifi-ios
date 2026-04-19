import SwiftUI

/// Share an AI chat with another Akifi user. Owners can grant read or
/// read+write access; recipients then see the conversation in their own
/// chat list. Backed by `ai_conversation_shares` (see migration
/// 20260419_ai_conversation_shares.sql).
struct ShareConversationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppViewModel.self) private var appViewModel

    let conversation: AiConversation

    @State private var emailInput = ""
    @State private var permission: SharePermission = .read
    @State private var existingShares: [AiConversationShare] = []
    @State private var profilesById: [String: Profile] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    private let repo = AiRepository()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(String(localized: "share.conversation.privacyWarning"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Section(String(localized: "share.conversation.invite")) {
                    TextField(String(localized: "share.conversation.email"), text: $emailInput)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()

                    Picker(String(localized: "share.conversation.permission"), selection: $permission) {
                        Text(String(localized: "share.conversation.permission.read")).tag(SharePermission.read)
                        Text(String(localized: "share.conversation.permission.write")).tag(SharePermission.write)
                    }
                    .pickerStyle(.segmented)

                    Button {
                        Task { await invite() }
                    } label: {
                        Label(String(localized: "share.conversation.send"), systemImage: "paperplane")
                    }
                    .disabled(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                }

                if let infoMessage {
                    Section { Text(infoMessage).font(.caption).foregroundStyle(.green) }
                }
                if let errorMessage {
                    Section { Text(errorMessage).font(.caption).foregroundStyle(.red) }
                }

                Section(String(localized: "share.conversation.access")) {
                    if existingShares.isEmpty {
                        Text(String(localized: "share.conversation.noShares"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(existingShares) { share in
                            shareRow(share)
                        }
                        .onDelete(perform: deleteShares)
                    }
                }
            }
            .navigationTitle(String(localized: "share.conversation.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "common.done")) { dismiss() }
                }
            }
            .task { await reloadShares() }
            .overlay {
                if isLoading { ProgressView().controlSize(.large) }
            }
        }
    }

    private func shareRow(_ share: AiConversationShare) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(profilesById[share.sharedWithUserId]?.fullName
                     ?? profilesById[share.sharedWithUserId]?.email
                     ?? share.sharedWithUserId.prefix(8).description)
                    .font(.subheadline)
                Text(share.permission == .write
                     ? String(localized: "share.conversation.permission.write")
                     : String(localized: "share.conversation.permission.read"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Actions

    private func invite() async {
        let email = emailInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.contains("@") else {
            errorMessage = String(localized: "share.conversation.invalidEmail")
            return
        }
        isLoading = true
        errorMessage = nil
        infoMessage = nil
        defer { isLoading = false }

        do {
            guard let recipientId = try await repo.findUserByEmail(email) else {
                errorMessage = String(localized: "share.conversation.userNotFound")
                return
            }
            if recipientId == appViewModel.dataStore.profile?.id {
                errorMessage = String(localized: "share.conversation.cannotShareWithSelf")
                return
            }
            _ = try await repo.shareConversation(
                conversationId: conversation.id,
                withUserId: recipientId,
                permission: permission
            )
            emailInput = ""
            infoMessage = String(localized: "share.conversation.invited")
            await reloadShares()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteShares(at offsets: IndexSet) {
        let toDelete = offsets.map { existingShares[$0] }
        Task {
            isLoading = true
            for share in toDelete {
                try? await repo.revokeShare(share.id)
            }
            isLoading = false
            await reloadShares()
        }
    }

    private func reloadShares() async {
        do {
            let shares = try await repo.listShares(conversationId: conversation.id)
            existingShares = shares
            // Hydrate profile names for the listed recipients (best-effort).
            let ids = Array(Set(shares.map { $0.sharedWithUserId }))
            if !ids.isEmpty {
                let profiles = appViewModel.dataStore.profilesMap
                profilesById = Dictionary(uniqueKeysWithValues: ids.compactMap { id in
                    profiles[id].map { (id, $0) }
                })
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
