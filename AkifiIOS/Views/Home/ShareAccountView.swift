import SwiftUI
@preconcurrency import Supabase

struct ShareAccountView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    let account: Account

    @State private var inviteRole: AccountRole = .editor
    @State private var inviteLink: String?
    @State private var isGenerating = false
    @State private var copied = false
    @State private var members: [AccountMember] = []
    @State private var error: String?

    private let supabase = SupabaseManager.shared.client

    var body: some View {
        NavigationStack {
            List {
                Section("Участники") {
                    if members.isEmpty {
                        Text("Только вы")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(members) { member in
                            HStack {
                                Image(systemName: "person.circle.fill")
                                    .foregroundStyle(Color.accent)
                                Text(member.userId.prefix(8) + "...")
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

                Section("Пригласить") {
                    Picker("Роль", selection: $inviteRole) {
                        Text("Редактор").tag(AccountRole.editor)
                        Text("Наблюдатель").tag(AccountRole.viewer)
                    }

                    Button {
                        Task { await generateInvite() }
                    } label: {
                        HStack {
                            Label("Создать ссылку", systemImage: "link.badge.plus")
                            if isGenerating {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isGenerating)
                }

                if let inviteLink {
                    Section("Ссылка-приглашение") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(inviteLink)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)

                            HStack(spacing: 12) {
                                Button {
                                    UIPasteboard.general.string = inviteLink
                                    copied = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                                } label: {
                                    Label(copied ? "Скопировано!" : "Копировать", systemImage: copied ? "checkmark" : "doc.on.doc")
                                        .font(.subheadline)
                                }

                                ShareLink(item: inviteLink) {
                                    Label("Поделиться", systemImage: "square.and.arrow.up")
                                        .font(.subheadline)
                                }
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
            .navigationTitle("Совместный доступ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .task { await loadMembers() }
        }
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

    private func generateInvite() async {
        isGenerating = true
        error = nil

        do {
            let token = UUID().uuidString
            let input: [String: String] = [
                "account_id": account.id,
                "role": inviteRole.rawValue,
                "token": token
            ]

            try await supabase
                .from("account_invites")
                .insert(input)
                .execute()

            inviteLink = "akifi://invite/\(token)"
        } catch {
            self.error = error.localizedDescription
        }

        isGenerating = false
    }
}
