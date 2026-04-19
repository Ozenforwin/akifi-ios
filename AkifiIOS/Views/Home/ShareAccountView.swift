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
    /// Draft split percentages (0...100) per userId. Normalized from the
    /// raw `split_weight` values on load and renormalized to sum-to-100
    /// on save so fractional drift from steppers doesn't snowball.
    @State private var splitPercents: [String: Double] = [:]
    @State private var isSavingSplits = false
    @State private var splitSaveOK = false

    private let supabase = SupabaseManager.shared.client

    private var inviteCode: String? {
        inviteToken.map { String($0.prefix(12)).uppercased() }
    }

    /// True iff we have ≥ 2 members and can meaningfully edit percentages.
    private var canEditSplits: Bool { members.count >= 2 }

    private var totalSplitPercent: Double {
        splitPercents.values.reduce(0, +)
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
                            VStack(alignment: .leading, spacing: 6) {
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

                                if canEditSplits {
                                    splitStepper(for: member.userId)
                                }
                            }
                            .padding(.vertical, 2)
                        }

                        if canEditSplits {
                            splitsSummary
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
        "https://akifi.pro/invite/\(token)"
    }

    private func shareMessage(for token: String) -> String {
        let name = account.name
        let link = deepLink(for: token)
        let shortCode = formatCode(token)
        return String(localized: "share.messageV3.\(name).\(shortCode).\(link)")
    }

    private func loadMembers() async {
        do {
            members = try await supabase
                .from("account_members")
                .select()
                .eq("account_id", value: account.id)
                .execute()
                .value
            // Normalize raw weights → sum-to-100 percentages for the UI.
            // Empty/all-zero weights fall back to equal split so the first
            // time a user opens the sheet they see a sensible default.
            let rawTotal: Decimal = members.reduce(0) { $0 + $1.splitWeight }
            if rawTotal > 0 {
                var pct: [String: Double] = [:]
                for m in members {
                    let fraction = m.splitWeight / rawTotal
                    let dbl = (fraction as NSDecimalNumber).doubleValue
                    pct[m.userId] = (dbl * 100).rounded()
                }
                splitPercents = Self.renormalize(pct)
            } else if !members.isEmpty {
                let equal = 100.0 / Double(members.count)
                splitPercents = Self.renormalize(
                    Dictionary(uniqueKeysWithValues: members.map { ($0.userId, equal) })
                )
            }
        } catch {
            // Account may not have members yet
        }
    }

    /// Ensures the split percentages sum to exactly 100 by absorbing
    /// rounding drift into the largest bucket. Keeps the visible "Total"
    /// counter honest without restricting stepper increments.
    private static func renormalize(_ pct: [String: Double]) -> [String: Double] {
        let sum = pct.values.reduce(0, +)
        guard sum > 0 else { return pct }
        var result = pct
        let drift = 100.0 - sum
        if let maxKey = result.max(by: { $0.value < $1.value })?.key {
            result[maxKey] = max(0, (result[maxKey] ?? 0) + drift)
        }
        return result
    }

    private func memberName(_ userId: String) -> String {
        if let profile = appViewModel.dataStore.profilesMap[userId] {
            return profile.fullName ?? profile.email ?? String(userId.prefix(8)) + "..."
        }
        return String(userId.prefix(8)) + "..."
    }

    // MARK: - Split weights UI

    @ViewBuilder
    private func splitStepper(for userId: String) -> some View {
        let current = splitPercents[userId] ?? 0
        HStack(spacing: 12) {
            Text(String(localized: "share.split.share"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                HapticManager.light()
                splitPercents[userId] = max(0, current - 5)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(current > 0 ? Color.accent : .secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(current <= 0)

            Text("\(Int(current.rounded()))%")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .frame(minWidth: 44)

            Button {
                HapticManager.light()
                splitPercents[userId] = min(100, current + 5)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(current < 100 ? Color.accent : .secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(current >= 100)
        }
    }

    @ViewBuilder
    private var splitsSummary: some View {
        let total = Int(totalSplitPercent.rounded())
        let isValid = total != 0 && totalSplitPercent > 0
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "share.split.total"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(total)%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isValid ? (total == 100 ? .green : .orange) : .red)
            }
            if total != 100 && isValid {
                Text(String(localized: "share.split.willNormalize"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await saveSplits() }
            } label: {
                HStack {
                    if isSavingSplits { ProgressView().tint(.white) }
                    Text(splitSaveOK
                         ? String(localized: "share.split.saved")
                         : String(localized: "share.split.save"))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(isValid ? Color.accent : Color.gray)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!isValid || isSavingSplits)
        }
        .padding(.top, 8)
    }

    private func saveSplits() async {
        // Clamp + renormalize into sum-to-100; send raw percents as the
        // relative weights (Postgres NUMERIC(6,3) handles fractional).
        // SettlementCalculator re-normalizes anyway so what we persist
        // doesn't need to be exactly 100 — but we clean it up so future
        // UI loads show a tidy total.
        isSavingSplits = true
        splitSaveOK = false
        defer { isSavingSplits = false }

        let clean = Self.renormalize(splitPercents.mapValues { max(0, $0) })
        // Skip noops — don't hit the network if nothing changed.
        let changed = members.contains { m in
            let newPct = clean[m.userId] ?? 0
            // Reconstruct the normalized percentage the last load produced.
            let oldPct: Double = {
                let total = (members.reduce(Decimal(0)) { $0 + $1.splitWeight } as NSDecimalNumber).doubleValue
                guard total > 0 else { return 0 }
                return (m.splitWeight as NSDecimalNumber).doubleValue / total * 100
            }()
            return abs(newPct - oldPct) >= 0.5
        }
        guard changed else { splitSaveOK = true; return }

        struct UpdatePayload: Encodable {
            let split_weight: Double
        }
        do {
            for m in members {
                let pct = clean[m.userId] ?? 0
                // Persist as a 0..100 value; the calculator normalizes it.
                try await supabase
                    .from("account_members")
                    .update(UpdatePayload(split_weight: pct))
                    .eq("id", value: m.id)
                    .execute()
            }
            splitPercents = clean
            splitSaveOK = true
            HapticManager.success()
            // Refresh local list so next open reads fresh weights.
            await loadMembers()
        } catch {
            self.error = error.localizedDescription
            HapticManager.error()
        }
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
    @State private var code: String
    @State private var isAccepting = false
    @State private var error: String?
    @State private var success: String?
    private let autoAccept: Bool

    private let supabase = SupabaseManager.shared.client

    init(initialCode: String = "") {
        _code = State(initialValue: initialCode)
        autoAccept = !initialCode.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if isAccepting {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.3)
                    Text(String(localized: "invite.joining"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                    Spacer()
                } else if let success {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.green)
                    Text(success)
                        .font(.headline)
                    Button(String(localized: "common.close")) { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 8)
                    Spacer()
                } else if let error {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    manualEntrySection
                    Spacer()
                } else {
                    manualEntrySection
                }
            }
            .navigationTitle(String(localized: "invite.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.close")) { dismiss() }
                }
            }
            .task {
                if autoAccept {
                    await acceptInvite()
                }
            }
        }
    }

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
                Task { await acceptInvite() }
            } label: {
                HStack {
                    Spacer()
                    Text(String(localized: "invite.accept"))
                        .fontWeight(.semibold)
                    Spacer()
                }
                .padding(.vertical, 12)
                .background(code.count >= 16 ? Color.accent : Color.gray)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(code.count < 16 || isAccepting)
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
        }
        .padding(.top, 20)
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
                if autoAccept {
                    try? await Task.sleep(for: .seconds(1.5))
                    dismiss()
                }
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
