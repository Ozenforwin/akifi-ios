import Foundation
import Supabase

/// Who is a member of which account, straight from `account_members`.
///
/// "Is this account shared?" used to be inferred from "someone else has
/// transactions on it", which is false for a freshly shared account until
/// the partner books something (B7). Membership is the real answer: every
/// account has its owner row, a shared one has more than one row. RLS
/// (`is_account_member`) returns the rows of every account the caller is a
/// member of, so one paged read serves Home, the transaction rows and the
/// shared-account screen (which used to fetch the same rows again — P7).
///
/// The snapshot is tagged with the user it was loaded for; while a different
/// user is signed in (or before the first load) every question is answered
/// with `nil` = unknown, and callers fall back to their legacy signal.
@Observable @MainActor
final class AccountMembershipStore {
    private(set) var membersByAccount: [String: [AccountMember]] = [:]
    private(set) var loadedForUserId: String?

    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var inFlightUserId: String?

    /// Network seam — tests replace it. Production: one complete-set read.
    @ObservationIgnored var fetchMembers: @Sendable () async throws -> [AccountMember] = {
        try await SupabasePaging.all("account_members") { count in
            SupabaseManager.shared.client
                .from("account_members")
                .select(count: count)
        }
    }

    // MARK: - Queries

    /// Members of `accountId`, or `nil` while unknown for `viewerId`.
    func members(of accountId: String, viewerId: String?) -> [AccountMember]? {
        guard let viewerId, viewerId == loadedForUserId else { return nil }
        return membersByAccount[accountId]
    }

    /// `account_id → member count`, `nil` while unknown for `viewerId`.
    func memberCounts(viewerId: String?) -> [String: Int]? {
        guard let viewerId, viewerId == loadedForUserId else { return nil }
        return membersByAccount.mapValues(\.count)
    }

    /// `true` when the account has more than one member, `nil` while unknown.
    func isShared(_ accountId: String, viewerId: String?) -> Bool? {
        members(of: accountId, viewerId: viewerId).map { $0.count > 1 }
    }

    /// Ids of every account with more than one member, `nil` while unknown.
    func sharedAccountIds(viewerId: String?) -> Set<String>? {
        guard let viewerId, viewerId == loadedForUserId else { return nil }
        return Set(membersByAccount.filter { $0.value.count > 1 }.keys)
    }

    // MARK: - Loading

    /// Reloads the snapshot unless one for `viewerId` is younger than
    /// `maxAge`. Concurrent callers share one request. A failed read keeps
    /// the previous snapshot (offline must not flip shared accounts back to
    /// "personal").
    func refresh(viewerId: String?, maxAge: TimeInterval = 60, force: Bool = false) async {
        guard let viewerId else { return }
        if !force, viewerId == loadedForUserId, let loadedAt,
           Date().timeIntervalSince(loadedAt) < maxAge {
            return
        }
        if let inFlight, inFlightUserId == viewerId {
            await inFlight.value
            return
        }
        let fetch = fetchMembers
        let task = Task { @MainActor [weak self] in
            do {
                let rows = try await fetch()
                self?.apply(rows, for: viewerId)
            } catch {
                AppLogger.data.debug("account members load: \(error.localizedDescription)")
            }
        }
        inFlight = task
        inFlightUserId = viewerId
        await task.value
        if inFlightUserId == viewerId {
            inFlight = nil
            inFlightUserId = nil
        }
    }

    /// Installs a snapshot. Internal so tests can seed it without a network.
    func apply(_ rows: [AccountMember], for viewerId: String, at date: Date = Date()) {
        let grouped = Dictionary(grouping: rows, by: \.accountId)
        // Equal snapshots are not re-assigned: every observer (Home, each
        // visible transaction row) would re-render for nothing.
        if Self.signature(grouped) != Self.signature(membersByAccount) {
            membersByAccount = grouped
        }
        if loadedForUserId != viewerId { loadedForUserId = viewerId }
        loadedAt = date
    }

    private static func signature(_ byAccount: [String: [AccountMember]]) -> [String: [String]] {
        byAccount.mapValues { members in
            members.map { "\($0.id)|\($0.userId)|\($0.role.rawValue)|\($0.splitWeight)" }
        }
    }
}
