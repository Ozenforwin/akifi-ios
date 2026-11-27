import SwiftUI
@preconcurrency import Supabase

// MARK: - Invite preview (S2)

/// What the server can tell about an invite before anyone joins.
///
/// Comes from the `preview_invite(p_token)` RPC. Until that RPC is
/// deployed (or when it fails) the preview is nil and the confirmation
/// screen says it can't tell who sent the link — joining still needs an
/// explicit tap either way.
struct InvitePreview: Equatable {
    enum Status: Equatable {
        case pending
        case expired
        case notFound
    }

    let status: Status
    let kind: AcceptInviteView.InviteKind?
    /// "viewer" | "editor"
    let role: String?
    let inviterName: String?
    let targetName: String?
    /// Budgets: false when the budget has no category filter — then every
    /// expense of the new member counts and is visible to the others.
    let budgetHasCategoryFilter: Bool?

    /// Parses the RPC's jsonb answer:
    /// `{"found": true, "kind": "budget", "role": "viewer",
    ///   "inviter_name": "…", "target_name": "…", "category_filter": false}`
    /// or `{"found": false, "error": "invite_expired" | "invite_not_found"}`.
    /// Booleans may arrive as JSON booleans or as "true"/"false" strings.
    static func decode(_ data: Data) -> InvitePreview? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func bool(_ key: String) -> Bool? {
            if let value = json[key] as? Bool { return value }
            if let value = json[key] as? String { return value == "true" ? true : (value == "false" ? false : nil) }
            return nil
        }
        func text(_ key: String) -> String? {
            guard let value = json[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let found = bool("found") else { return nil }
        guard found else {
            let status: Status = text("error") == "invite_expired" ? .expired : .notFound
            return InvitePreview(status: status, kind: nil, role: nil, inviterName: nil,
                                 targetName: nil, budgetHasCategoryFilter: nil)
        }
        let kind: AcceptInviteView.InviteKind? = switch text("kind") {
        case "account": .account
        case "budget": .budget
        default: nil
        }
        return InvitePreview(
            status: .pending,
            kind: kind,
            role: text("role"),
            inviterName: text("inviter_name"),
            targetName: text("target_name"),
            budgetHasCategoryFilter: bool("category_filter")
        )
    }
}

/// The confirmation copy: who, where, which role, and what each side will
/// see. A pure function of the link and the preview, so every branch is
/// testable.
struct InviteDisclosure: Equatable {
    let title: String
    let inviterLine: String?
    let targetLine: String?
    let roleLine: String?
    /// What joining shares, worst case first.
    let shares: [String]
    /// Shown when the server couldn't say who sent the link.
    let warning: String?

    static func make(linkKind: AcceptInviteView.InviteKind, preview: InvitePreview?) -> InviteDisclosure {
        let known = preview?.status == .pending ? preview : nil
        let kind = known?.kind ?? linkKind

        let title = kind == .budget
            ? String(localized: "invite.confirm.title.budget")
            : String(localized: "invite.confirm.title.account")

        var shares: [String] = []
        switch kind {
        case .budget:
            shares.append(String(localized: "invite.confirm.budget.seeBudget"))
            if known?.budgetHasCategoryFilter == false {
                shares.append(String(localized: "invite.confirm.budget.allExpenses"))
            } else {
                shares.append(String(localized: "invite.confirm.budget.yourExpenses"))
            }
        case .account:
            shares.append(String(localized: "invite.confirm.account.seeAccount"))
            shares.append(String(localized: "invite.confirm.account.yourTransactions"))
        }
        shares.append(String(localized: "invite.confirm.profile"))
        if known?.kind == nil {
            // Without the server's word the link may open the other kind
            // (the accept flow falls back between them) — say so.
            shares.append(kind == .budget
                ? String(localized: "invite.confirm.maybeAccount")
                : String(localized: "invite.confirm.maybeBudget"))
        }

        let roleLine: String? = switch known?.role {
        case "viewer": String(localized: "invite.confirm.role.viewer")
        case "editor": String(localized: "invite.confirm.role.editor")
        default: nil
        }
        let targetLine: String? = known?.targetName.map { name in
            kind == .budget
                ? String(localized: "invite.confirm.target.budget \(name)")
                : String(localized: "invite.confirm.target.account \(name)")
        }

        return InviteDisclosure(
            title: title,
            inviterLine: known?.inviterName.map { String(localized: "invite.confirm.from \($0)") },
            targetLine: targetLine,
            roleLine: roleLine,
            shares: shares,
            warning: known?.inviterName == nil ? String(localized: "invite.confirm.unknownInviter") : nil
        )
    }
}

// MARK: - Accept Invite View (for receiving user)

struct AcceptInviteView: View {
    /// What the invite joins. Same UI and error codes for both — only the
    /// accepting RPC differs.
    enum InviteKind {
        case account, budget

        var rpcName: String {
            switch self {
            case .account: "accept_account_invite"
            case .budget: "accept_budget_invite"
            }
        }
    }

    private enum Phase: Equatable {
        /// Typing a code by hand (Settings → "Принять приглашение").
        case enterCode
        /// Who / what / role / what is shared, with "Вступить" (S2).
        case confirm
        case accepting
        case success
        case failure(String)
    }

    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var code: String
    @State private var phase: Phase
    @State private var preview: InvitePreview?
    @State private var isLoadingPreview = false
    /// Opened from a link (vs typed in Settings).
    private let fromLink: Bool
    private let kind: InviteKind

    private let supabase = SupabaseManager.shared.client
    /// Fetches the invite preview; nil when unavailable. Injected so the
    /// screen can be exercised without the network.
    private let previewLoader: @MainActor (_ token: String) async -> InvitePreview?

    init(
        initialCode: String = "",
        kind: InviteKind = .account,
        previewLoader: @escaping @MainActor (_ token: String) async -> InvitePreview? = AcceptInviteView.fetchPreview
    ) {
        _code = State(initialValue: initialCode)
        fromLink = !initialCode.isEmpty
        // A link never joins by itself: it opens the confirmation (S2).
        _phase = State(initialValue: initialCode.isEmpty ? .enterCode : .confirm)
        self.kind = kind
        self.previewLoader = previewLoader
    }

    private var cleanCode: String {
        code.replacingOccurrences(of: " ", with: "").lowercased()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch phase {
                case .enterCode:
                    manualEntrySection
                    Spacer()
                case .confirm:
                    confirmationSection
                case .accepting:
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.3)
                    Text(String(localized: "invite.joining"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                    Spacer()
                case .success:
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text((preview?.kind ?? kind) == .budget
                         ? String(localized: "invite.success.budget")
                         : String(localized: "invite.success"))
                        .font(.headline)
                    Button(String(localized: "common.close")) { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 8)
                    Spacer()
                case .failure(let message):
                    Spacer()
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    manualEntrySection
                    Spacer()
                }
            }
            .navigationTitle(String(localized: "invite.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.close")) { dismiss() }
                }
            }
            .task(id: phase == .confirm ? cleanCode : "") {
                guard phase == .confirm else { return }
                await loadPreview()
            }
        }
    }

    // MARK: - Confirmation (S2)

    private var confirmationSection: some View {
        let disclosure = InviteDisclosure.make(linkKind: kind, preview: preview)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Spacer()
                    Image(systemName: (preview?.kind ?? kind) == .budget ? "chart.pie.fill" : "person.2.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accent.gradient)
                        .accessibilityHidden(true)
                    Spacer()
                }

                Text(disclosure.title)
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)

                if isLoadingPreview {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        if let line = disclosure.inviterLine {
                            Text(line).font(.headline)
                        }
                        if let line = disclosure.targetLine {
                            Text(line).font(.subheadline)
                        }
                        if let line = disclosure.roleLine {
                            Text(line).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }

                    if let warning = disclosure.warning {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "exclamationmark.shield.fill")
                                .foregroundStyle(.orange)
                                .accessibilityHidden(true)
                            Text(warning)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text(String(localized: "invite.confirm.sharesHeader"))
                            .font(.headline)
                        ForEach(disclosure.shares, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "eye")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Text(item)
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button {
                    Task { await acceptInvite() }
                } label: {
                    Text(String(localized: "invite.confirm.join"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accent)
                .disabled(isLoadingPreview)

                Button {
                    if fromLink { dismiss() } else { phase = .enterCode }
                } label: {
                    Text(String(localized: "common.cancel"))
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    private struct PreviewParams: Encodable {
        let p_token: String
    }

    /// `preview_invite(p_token)`; nil when the RPC isn't deployed yet,
    /// offline, or the answer doesn't parse — the screen then falls back
    /// to the link's kind and says it can't tell who sent the link.
    static func fetchPreview(token: String) async -> InvitePreview? {
        let client = SupabaseManager.shared.client
        do {
            let data = try await withTimeout(seconds: 6) {
                // bounded-fetch: preview_invite returns a single jsonb object, not a row set.
                try await client
                    .rpc("preview_invite", params: PreviewParams(p_token: token))
                    .execute()
                    .data
            }
            return InvitePreview.decode(data)
        } catch {
            return nil
        }
    }

    private func loadPreview() async {
        let token = cleanCode
        guard token.count >= DeepLink.minimumInviteCodeLength else { return }
        isLoadingPreview = true
        defer { isLoadingPreview = false }
        preview = await previewLoader(token)
        switch preview?.status {
        case .expired?: phase = .failure(String(localized: "invite.errorExpired"))
        case .notFound?: phase = .failure(String(localized: "invite.errorNotFound"))
        default: break
        }
    }

    // MARK: - Manual entry

    private var manualEntrySection: some View {
        VStack(spacing: 12) {
            Text(String(localized: "invite.pasteHint"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField(String(localized: "invite.codePlaceholder"), text: $code)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)

            Button {
                // Typed codes go through the same confirmation as links.
                preview = nil
                phase = .confirm
            } label: {
                HStack {
                    Spacer()
                    Text(String(localized: "invite.continue"))
                        .fontWeight(.semibold)
                    Spacer()
                }
                .padding(.vertical, 12)
                .background(cleanCode.count >= 16 ? Color.accent : Color.gray)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(cleanCode.count < 16)
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
        }
        .padding(.top, 20)
    }

    // MARK: - Accept (only from the "Вступить" button)

    private struct AcceptParams: Encodable {
        let p_token: String
    }

    /// Normalized accept-RPC outcome. The account RPC returns `success` as
    /// a jsonb boolean, the budget RPC as the string "true" — parse both.
    private struct AcceptOutcome {
        let success: Bool
        let errorCode: String?
    }

    private func callAcceptRPC(_ rpcName: String, token: String) async throws -> AcceptOutcome {
        // bounded-fetch: the accept RPCs return a single jsonb object, not a row set.
        let data = try await supabase
            .rpc(rpcName, params: AcceptParams(p_token: token))
            .execute()
            .data
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let success = (json["success"] as? Bool)
            ?? ((json["success"] as? String) == "true")
        return AcceptOutcome(success: success, errorCode: json["error"] as? String)
    }

    private func acceptInvite() async {
        let token = cleanCode
        guard token.count >= DeepLink.minimumInviteCodeLength else { return }
        // The server knows the kind; the link's kind is only a guess.
        let primary = preview?.kind ?? kind

        phase = .accepting
        do {
            var outcome = try await callAcceptRPC(primary.rpcName, token: token)

            // Without a preview the user doesn't know (and shouldn't care)
            // whether a code opens an account or a budget — both share the
            // "/invite/*" universal-link path. When the primary kind
            // doesn't recognize the token, try the other one.
            if !outcome.success, outcome.errorCode == "invite_not_found" {
                let other: InviteKind = primary == .account ? .budget : .account
                let secondTry = try await callAcceptRPC(other.rpcName, token: token)
                if secondTry.success || secondTry.errorCode != "invite_not_found" {
                    outcome = secondTry
                }
            }

            if outcome.success {
                phase = .success
                await appViewModel.dataStore.loadAll()
                code = ""
                if fromLink {
                    try? await Task.sleep(for: .seconds(1.5))
                    dismiss()
                }
            } else {
                let message: String = switch outcome.errorCode ?? "unknown" {
                case "invite_not_found": String(localized: "invite.errorNotFound")
                case "invite_expired": String(localized: "invite.errorExpired")
                case "already_member": String(localized: "invite.errorAlreadyMember")
                default: String(localized: "invite.errorUnknown")
                }
                phase = .failure(message)
            }
        } catch {
            phase = .failure(error.localizedDescription)
        }
    }
}
