import SwiftUI
@preconcurrency import Supabase

/// Sharing sheet for a budget — mirror of `ShareAccountView` without the
/// split-weight machinery (budget progress is one shared number).
struct ShareBudgetView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    let budget: Budget

    @State private var inviteRole: AccountRole = .editor
    @State private var inviteToken: String?
    @State private var isGenerating = false
    @State private var copied = false
    @State private var members: [BudgetMember] = []
    @State private var error: String?

    private let supabase = SupabaseManager.shared.client

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
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section {
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
                } header: {
                    Text(String(localized: "share.invite"))
                } footer: {
                    // Progress covers everyone's spending (server RPC feeds
                    // the invisible remainder); only amounts/dates cross the
                    // privacy boundary, never descriptions or merchants.
                    Text(String(localized: "share.budget.progressHint"))
                }

                if let token = inviteToken {
                    Section(String(localized: "share.inviteCode")) {
                        VStack(spacing: 16) {
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
                                    UIPasteboard.general.string = deepLink(for: token)
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

                                ShareLink(item: shareMessage(for: token)) {
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
        let short = String(token.prefix(16)).uppercased()
        var result = ""
        for (i, char) in short.enumerated() {
            if i > 0 && i % 4 == 0 { result += "  " }
            result.append(char)
        }
        return result
    }

    private func deepLink(for token: String) -> String {
        // Same universal-link path as account invites: the AASA on
        // akifi.pro whitelists only "/invite/*", and the accept flow is
        // type-agnostic anyway (tries both RPCs). A dedicated
        // "/budget-invite/*" path would open Safari instead of the app.
        "https://akifi.pro/invite/\(token)"
    }

    private func shareMessage(for token: String) -> String {
        String(localized: "share.budget.messageV1.\(budget.name).\(formatCode(token)).\(deepLink(for: token))")
    }

    private func memberName(_ userId: String) -> String {
        if let profile = appViewModel.dataStore.profilesMap[userId] {
            return profile.fullName ?? profile.email ?? String(userId.prefix(8)) + "..."
        }
        return String(userId.prefix(8)) + "..."
    }

    private func loadMembers() async {
        // Prefer the already-loaded map; fall back to a direct fetch when
        // the sheet opens before loadAll caught up.
        if let cached = appViewModel.dataStore.budgetMembersByBudget[budget.id], !cached.isEmpty {
            members = cached
            return
        }
        do {
            members = try await supabase
                .from("budget_members")
                .select()
                .eq("budget_id", value: budget.id)
                .execute()
                .value
        } catch {
            // Budget may not have members yet
        }
    }

    private struct InviteParams: Encodable {
        let p_budget_id: String
        let p_role: String
        let p_expires_hours: Int
    }

    private func generateInvite() async {
        isGenerating = true
        error = nil
        do {
            let token: String = try await supabase
                .rpc("create_budget_invite", params: InviteParams(
                    p_budget_id: budget.id,
                    p_role: inviteRole.rawValue,
                    p_expires_hours: 72
                ))
                .execute()
                .value
            inviteToken = token
        } catch {
            self.error = error.localizedDescription
        }
        isGenerating = false
    }
}
