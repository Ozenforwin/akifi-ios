import Foundation
import Supabase

/// Which of the user's accounts are shared, from `account_members` (B7).
///
/// "Shared" used to be inferred from "someone else has a transaction on
/// it". A freshly shared account therefore did not count as shared for its
/// owner until the partner wrote something: no «Оплачено с» picker, the
/// owner's expenses were saved without an auto-transfer and never reached
/// the settlement. Membership is the fact; transactions are a side effect.
///
/// One paged read of `account_members` (RLS returns the member rows of
/// every account the caller belongs to), kept per signed-in user so a
/// sign-out/sign-in on the same device never reuses the previous user's map.
@Observable @MainActor
final class AccountSharingIndex {
    static let shared = AccountSharingIndex()

    /// `account_id → number of member rows`, for `loadedForUserId`.
    private(set) var memberCounts: [String: Int] = [:]
    private(set) var loadedForUserId: String?

    @ObservationIgnored private var lastLoadedAt: Date?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var inFlightUserId: String?
    /// The user the latest `refresh` was for; a load finishing for anyone
    /// else (sign-out/sign-in mid-request) is dropped.
    @ObservationIgnored private var requestedUserId: String?

    /// Pure rule, shared by every caller (forms, carousel, tests):
    /// 1. an account owned by someone else is shared with me by definition;
    /// 2. with membership loaded for THIS user, more than one member row;
    /// 3. membership not loaded yet (first frame, offline cold start) → the
    ///    legacy heuristic, so the UI degrades to the old behaviour instead
    ///    of hiding sharing altogether.
    nonisolated static func isShared(
        _ account: Account,
        currentUserId: String?,
        memberCounts: [String: Int]?,
        fallback: () -> Bool
    ) -> Bool {
        if let uid = currentUserId, account.userId != uid { return true }
        if let memberCounts { return (memberCounts[account.id] ?? 0) > 1 }
        return fallback()
    }

    func isShared(_ account: Account, currentUserId: String?, fallback: () -> Bool) -> Bool {
        let counts = (currentUserId != nil && currentUserId == loadedForUserId) ? memberCounts : nil
        return Self.isShared(account, currentUserId: currentUserId, memberCounts: counts, fallback: fallback)
    }

    /// The legacy heuristic, used only until membership is loaded.
    static func hasOtherMembersRows(_ account: Account, currentUserId: String?, transactions: [Transaction]) -> Bool {
        guard let uid = currentUserId else { return false }
        return transactions.contains { $0.accountId == account.id && $0.userId != uid }
    }

    /// Refresh the member map. Coalesces concurrent callers and skips the
    /// round-trip when the map for this user is younger than `maxAge`.
    /// Failures keep the previous map (or the fallback) — sharing badges are
    /// not worth an error banner.
    func refresh(currentUserId: String?, maxAge: TimeInterval = 60) async {
        guard let uid = currentUserId else { return }
        requestedUserId = uid
        if loadedForUserId != uid {
            memberCounts = [:]
            loadedForUserId = nil
            lastLoadedAt = nil
        }
        if let last = lastLoadedAt, Date().timeIntervalSince(last) < maxAge { return }
        if let task = inFlight, inFlightUserId == uid {
            await task.value
            return
        }
        let task = Task { [weak self] () -> Void in
            await self?.load(for: uid)
        }
        inFlight = task
        inFlightUserId = uid
        await task.value
        if inFlightUserId == uid {
            inFlight = nil
            inFlightUserId = nil
        }
    }

    private struct MemberRow: Decodable, Sendable, Identifiable {
        let id: String
        let accountId: String

        enum CodingKeys: String, CodingKey {
            case id
            case accountId = "account_id"
        }
    }

    private func load(for uid: String) async {
        let client = SupabaseManager.shared.client
        do {
            let rows: [MemberRow] = try await SupabasePaging.all("account_members") { count in
                client
                    .from("account_members")
                    .select("id, account_id", count: count)
            }
            var counts: [String: Int] = [:]
            for row in rows { counts[row.accountId, default: 0] += 1 }
            // A different user may have signed in while this was in flight.
            guard requestedUserId == uid else { return }
            memberCounts = counts
            loadedForUserId = uid
            lastLoadedAt = Date()
        } catch {
            AppLogger.data.debug("account sharing index: \(error.localizedDescription)")
        }
    }
}
