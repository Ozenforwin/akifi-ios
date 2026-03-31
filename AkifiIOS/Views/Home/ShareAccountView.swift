import SwiftUI
@preconcurrency import Supabase

struct ShareAccountView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    let account: Account

    @State private var inviteRole: AccountRole = .editor
    @State private var inviteToken: String?
    @State private var isGenerating = false
    @State private var copied = false
    @State private var members: [AccountMember] = []
    @State private var error: String?

    private let supabase = SupabaseManager.shared.client

    private var inviteCode: String? {
        inviteToken.map { String($0.prefix(12)).uppercased() }
    }

    var body: some View {
        NavigationStack {
            List {
                Section(String(localized: "share.members")) {
                    if members.isEmpty {
                        Text(String(localized: "share.onlyYou"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(members) { member in
                            HStack {
                                Image(systemName: "person.circle.fill")
                                    .foregroundStyle(Color.accent)
                                Text(memberName(member.userId))
                                    .font(.subheadline)
                                Spacer()
                                Text(member.role.rawValue.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color(.systemBackground))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }

                Section(String(localized: "share.invite")) {
                    Picker(String(localized: "share.role"), selection: $inviteRole) {
                        Text(String(localized: "share.editor")).tag(AccountRole.editor)
                        Text(String(localized: "share.viewer")).tag(AccountRole.viewer)
                    }

                    Button {
                        Task { await generateInvite() }
                    } label: {
                        HStack {
                            Label(String(localized: "share.createCode"), systemImage: "person.badge.plus")
                            if isGenerating {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isGenerating)
                }

                if let token = inviteToken {
                    Section(String(localized: "share.inviteCode")) {
                        VStack(spacing: 16) {
                            // Large readable code
                            Text(formatCode(token))
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .tracking(2)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)

                            Text(String(localized: "share.codeHint"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)

                            HStack(spacing: 12) {
                                Button {
                                    UIPasteboard.general.string = token
                                    copied = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                                } label: {
                                    Label(copied ? String(localized: "share.copied") : String(localized: "share.copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                                        .font(.subheadline.weight(.medium))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(Color(.systemGray6))
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)

                                let shareText = String(localized: "share.messageTemplate.\(account.name).\(token)")
                                ShareLink(item: shareText) {
                                    Label(String(localized: "share.send"), systemImage: "square.and.arrow.up")
                                        .font(.subheadline.weight(.medium))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(Color.accent.opacity(0.15))
                                        .foregroundStyle(Color.accent)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                            }
                        }
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
            .navigationTitle(String(localized: "share.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.close")) { dismiss() }
                }
            }
            .task { await loadMembers() }
        }
    }

    private func formatCode(_ token: String) -> String {
        // Show first 16 chars in groups of 4 for readability
        let short = String(token.prefix(16)).uppercased()
        var result = ""
        for (i, char) in short.enumerated() {
            if i > 0 && i % 4 == 0 { result += " " }
            result.append(char)
        }
        return result
    }

    private func loadMembers() async {
        do {
            members = try await supabase
                .from("account_members")
                .select()
                .eq("account_id", value: account.id)
                .execute()
                .value
        } catch {
            // Account may not have members yet
        }
    }

    private func memberName(_ userId: String) -> String {
        if let profile = appViewModel.dataStore.profilesMap[userId] {
            return profile.fullName ?? profile.email ?? String(userId.prefix(8)) + "..."
        }
        return String(userId.prefix(8)) + "..."
    }

    private struct InviteParams: Encodable {
        let p_account_id: String
        let p_role: String
        let p_expires_hours: Int
    }

    private func generateInvite() async {
        isGenerating = true
        error = nil

        do {
            let response: String = try await supabase
                .rpc("create_account_invite", params: InviteParams(
                    p_account_id: account.id,
                    p_role: inviteRole.rawValue,
                    p_expires_hours: 72
                ))
                .execute()
                .value

            inviteToken = response.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        } catch {
            self.error = error.localizedDescription
        }

        isGenerating = false
    }
}

// MARK: - Accept Invite View (for receiving user)

struct AcceptInviteView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var isAccepting = false
    @State private var error: String?
    @State private var success: String?

    private let supabase = SupabaseManager.shared.client

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(String(localized: "invite.pasteHint"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        TextField(String(localized: "invite.codePlaceholder"), text: $code)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()

                        Button {
                            Task { await acceptInvite() }
                        } label: {
                            HStack {
                                Spacer()
                                if isAccepting {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Text(String(localized: "invite.accept"))
                                        .fontWeight(.semibold)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 12)
                            .background(code.count >= 16 ? Color.accent : Color.gray)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(code.count < 16 || isAccepting)
                        .buttonStyle(.plain)
                    }
                }

                if let success {
                    Section {
                        Label(success, systemImage: "checkmark.circle.fill")
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
            .navigationTitle(String(localized: "invite.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.close")) { dismiss() }
                }
            }
        }
    }

    private struct AcceptParams: Encodable {
        let p_token: String
    }

    private func acceptInvite() async {
        let cleanCode = code.replacingOccurrences(of: " ", with: "").lowercased()
        guard cleanCode.count >= 16 else { return }

        isAccepting = true
        error = nil
        success = nil

        do {
            let response: [String: String] = try await supabase
                .rpc("accept_account_invite", params: AcceptParams(p_token: cleanCode))
                .execute()
                .value

            if response["success"] == "true" {
                success = String(localized: "invite.success")
                await appViewModel.dataStore.loadAll()
                code = ""
            } else {
                let errCode = response["error"] ?? "unknown"
                switch errCode {
                case "invite_not_found": error = String(localized: "invite.errorNotFound")
                case "invite_expired": error = String(localized: "invite.errorExpired")
                case "already_member": error = String(localized: "invite.errorAlreadyMember")
                default: error = String(localized: "invite.errorUnknown")
                }
            }
        } catch {
            self.error = error.localizedDescription
        }

        isAccepting = false
    }
}
