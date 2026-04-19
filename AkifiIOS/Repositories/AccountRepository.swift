import Foundation
import Supabase

final class AccountRepository: Sendable {
    private let supabase = SupabaseManager.shared.client

    private struct MembershipRow: Decodable {
        let accountId: String
        let role: String
        let isPrimary: Bool

        enum CodingKeys: String, CodingKey {
            case accountId = "account_id"
            case role
            case isPrimary = "is_primary"
        }
    }

    func fetchAll() async throws -> [Account] {
        var accounts: [Account] = try await supabase
            .from("accounts")
            .select()
            .order("created_at")
            .execute()
            .value

        // Fetch per-user is_primary from account_members (same as Telegram app)
        let userId = try await SupabaseManager.shared.currentUserId()
        let memberships: [MembershipRow] = try await supabase
            .from("account_members")
            .select("account_id, role, is_primary")
            .eq("user_id", value: userId)
            .execute()
            .value

        let memberMap = Dictionary(uniqueKeysWithValues: memberships.map { ($0.accountId, $0) })

        for i in accounts.indices {
            if let membership = memberMap[accounts[i].id] {
                accounts[i].isPrimary = membership.isPrimary
            }
        }

        // Sort: primary first, then by creation date
        accounts.sort { a, b in
            if a.isPrimary != b.isPrimary { return a.isPrimary }
            return (a.createdAt ?? "") < (b.createdAt ?? "")
        }

        return accounts
    }

    func create(name: String, icon: String, color: String, initialBalance: Int64, currency: String = "rub", accountType: AccountType = .checking) async throws -> Account {
        struct CreateInput: Encodable {
            let user_id: String
            let name: String
            let icon: String
            let color: String
            let initial_balance: Int64
            let currency: String
            let account_type: String
        }

        // RLS policy requires user_id = auth.uid().
        // Migration 60 also sets DEFAULT auth.uid() server-side, so this is
        // belt-and-suspenders.
        let userId = try await SupabaseManager.shared.currentUserId()

        // iOS stores kopecks, DB stores whole rubles
        let balanceRubles = initialBalance / 100
        return try await supabase
            .from("accounts")
            .insert(CreateInput(
                user_id: userId,
                name: name,
                icon: icon,
                color: color,
                initial_balance: balanceRubles,
                currency: currency,
                account_type: accountType.rawValue
            ))
            .select()
            .single()
            .execute()
            .value
    }

    func update(id: String, name: String, icon: String, color: String, currency: String, initialBalance: Int64? = nil) async throws {
        struct UpdateInput: Encodable {
            let name: String
            let icon: String
            let color: String
            let currency: String
            let initial_balance: Int64?
        }

        let balanceRubles = initialBalance.map { $0 / 100 }
        try await supabase
            .from("accounts")
            .update(UpdateInput(name: name, icon: icon, color: color, currency: currency, initial_balance: balanceRubles))
            .eq("id", value: id)
            .execute()
    }

    func delete(id: String) async throws {
        try await supabase
            .from("accounts")
            .delete()
            .eq("id", value: id)
            .execute()
    }

    func setPrimary(id: String) async throws {
        try await supabase.rpc("set_my_primary_account", params: ["p_account_id": id]).execute()
    }
}
