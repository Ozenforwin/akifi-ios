import Foundation

/// One row of `public.debts` — the details of a «Долги» account (1:1 with an
/// `accounts` row whose `account_type = 'debt'`). Contract:
/// `.claude/design/debts-contract.md` §A1.
///
/// The money of a debt is NOT here: it is the debt account's ordinary
/// balance (`initial_balance + Σ income − Σ expense`). > 0 they owe me,
/// < 0 I owe them.
struct Debt: Codable, Sendable, Equatable, Identifiable {
    let accountId: String
    let userId: String
    var counterpartyName: String
    var counterpartyContact: String?
    /// "yyyy-MM-dd" — «вернуть до».
    var dueDate: String?
    /// A local reminder on `dueDate` (needs a due date, CHECK on the server).
    var remind: Bool
    var note: String?
    /// nil = open.
    var closedAt: String?
    let createdAt: String?
    let updatedAt: String?

    var id: String { accountId }
    var isClosed: Bool { closedAt != nil }

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case userId = "user_id"
        case counterpartyName = "counterparty_name"
        case counterpartyContact = "counterparty_contact"
        case dueDate = "due_date"
        case remind, note
        case closedAt = "closed_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        accountId: String, userId: String, counterpartyName: String,
        counterpartyContact: String? = nil, dueDate: String? = nil, remind: Bool = false,
        note: String? = nil, closedAt: String? = nil, createdAt: String? = nil, updatedAt: String? = nil
    ) {
        self.accountId = accountId; self.userId = userId; self.counterpartyName = counterpartyName
        self.counterpartyContact = counterpartyContact; self.dueDate = dueDate; self.remind = remind
        self.note = note; self.closedAt = closedAt; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try c.decode(String.self, forKey: .accountId)
        userId = try c.decode(String.self, forKey: .userId)
        counterpartyName = try c.decode(String.self, forKey: .counterpartyName)
        counterpartyContact = try c.decodeIfPresent(String.self, forKey: .counterpartyContact)
        dueDate = try c.decodeIfPresent(String.self, forKey: .dueDate).map { String($0.prefix(10)) }
        remind = (try? c.decodeIfPresent(Bool.self, forKey: .remind)) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note)
        closedAt = try c.decodeIfPresent(String.self, forKey: .closedAt)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

/// Sign of a debt balance (`debts_summary.direction`).
enum DebtDirection: String, Codable, Sendable, Equatable {
    /// balance > 0 — «мне должны».
    case owedToMe = "owed_to_me"
    /// balance < 0 — «я должен».
    case iOwe = "i_owe"
    /// balance = 0.
    case settled

    init(balance: Int64) {
        self = balance > 0 ? .owedToMe : (balance < 0 ? .iOwe : .settled)
    }

    /// Unknown future values read as "derive from the balance".
    static func tolerant(_ raw: String?, balance: Int64) -> DebtDirection {
        raw.flatMap(DebtDirection.init(rawValue:)) ?? DebtDirection(balance: balance)
    }
}

/// Response of `debts_summary()` (contract §A4) — one jsonb value.
///
/// Tolerant by design: `version` is read, unknown keys are ignored (future
/// versions only add keys), and a missing optional field never fails the
/// whole summary — only a row without `account_id` is dropped.
struct DebtsSummary: Codable, Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable, Identifiable {
        let accountId: String
        let name: String
        let icon: String?
        let color: String?
        /// Upper-case ISO code of the debt account.
        let currency: String
        /// Minor units (×100) of `currency`. > 0 they owe me.
        let balance: Int64
        let direction: DebtDirection
        let counterpartyName: String
        let counterpartyContact: String?
        let dueDate: String?
        let remind: Bool
        let note: String?
        let closedAt: String?
        let isClosed: Bool
        let isOverdue: Bool
        /// false: the account exists but its `debts` row is missing
        /// (interrupted two-step create) — offer to fill in the details.
        let hasDetails: Bool
        let txCount: Int
        let lastMovementAt: String?
        let createdAt: String?

        var id: String { accountId }

        enum CodingKeys: String, CodingKey {
            case accountId = "account_id"
            case name, icon, color, currency, balance, direction
            case counterpartyName = "counterparty_name"
            case counterpartyContact = "counterparty_contact"
            case dueDate = "due_date"
            case remind, note
            case closedAt = "closed_at"
            case isClosed = "is_closed"
            case isOverdue = "is_overdue"
            case hasDetails = "has_details"
            case txCount = "tx_count"
            case lastMovementAt = "last_movement_at"
            case createdAt = "created_at"
        }

        init(
            accountId: String, name: String, icon: String? = nil, color: String? = nil,
            currency: String, balance: Int64, direction: DebtDirection? = nil,
            counterpartyName: String? = nil, counterpartyContact: String? = nil,
            dueDate: String? = nil, remind: Bool = false, note: String? = nil,
            closedAt: String? = nil, isOverdue: Bool = false, hasDetails: Bool = true,
            txCount: Int = 0, lastMovementAt: String? = nil, createdAt: String? = nil
        ) {
            self.accountId = accountId; self.name = name; self.icon = icon; self.color = color
            self.currency = currency.uppercased(); self.balance = balance
            self.direction = direction ?? DebtDirection(balance: balance)
            self.counterpartyName = counterpartyName ?? name
            self.counterpartyContact = counterpartyContact; self.dueDate = dueDate
            self.remind = remind; self.note = note; self.closedAt = closedAt
            self.isClosed = closedAt != nil; self.isOverdue = isOverdue; self.hasDetails = hasDetails
            self.txCount = txCount; self.lastMovementAt = lastMovementAt; self.createdAt = createdAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            accountId = try c.decode(String.self, forKey: .accountId)
            let name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
            self.name = name ?? ""
            icon = (try? c.decodeIfPresent(String.self, forKey: .icon)) ?? nil
            color = (try? c.decodeIfPresent(String.self, forKey: .color)) ?? nil
            currency = ((try? c.decodeIfPresent(String.self, forKey: .currency)) ?? nil)?.uppercased() ?? "RUB"
            balance = Self.int64(c, .balance) ?? 0
            direction = DebtDirection.tolerant((try? c.decodeIfPresent(String.self, forKey: .direction)) ?? nil, balance: balance)
            counterpartyName = ((try? c.decodeIfPresent(String.self, forKey: .counterpartyName)) ?? nil) ?? self.name
            counterpartyContact = (try? c.decodeIfPresent(String.self, forKey: .counterpartyContact)) ?? nil
            dueDate = ((try? c.decodeIfPresent(String.self, forKey: .dueDate)) ?? nil).map { String($0.prefix(10)) }
            remind = ((try? c.decodeIfPresent(Bool.self, forKey: .remind)) ?? nil) ?? false
            note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil
            closedAt = (try? c.decodeIfPresent(String.self, forKey: .closedAt)) ?? nil
            isClosed = ((try? c.decodeIfPresent(Bool.self, forKey: .isClosed)) ?? nil) ?? (closedAt != nil)
            isOverdue = ((try? c.decodeIfPresent(Bool.self, forKey: .isOverdue)) ?? nil) ?? false
            hasDetails = ((try? c.decodeIfPresent(Bool.self, forKey: .hasDetails)) ?? nil) ?? true
            txCount = Int(Self.int64(c, .txCount) ?? 0)
            lastMovementAt = (try? c.decodeIfPresent(String.self, forKey: .lastMovementAt)) ?? nil
            createdAt = (try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil
        }

        /// bigint arrives as a JSON number; accept a numeric string too.
        static func int64(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int64? {
            if let v = try? c.decodeIfPresent(Int64.self, forKey: key) { return v }
            if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return Int64(d.rounded()) }
            if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Int64(s) }
            return nil
        }
    }

    /// Open debts only, one per currency, no FX.
    struct Total: Codable, Sendable, Equatable {
        let currency: String
        let owedToMe: Int64
        let iOwe: Int64
        let openCount: Int

        enum CodingKeys: String, CodingKey {
            case currency
            case owedToMe = "owed_to_me"
            case iOwe = "i_owe"
            case openCount = "open_count"
        }

        init(currency: String, owedToMe: Int64, iOwe: Int64, openCount: Int) {
            self.currency = currency.uppercased(); self.owedToMe = owedToMe; self.iOwe = iOwe; self.openCount = openCount
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            currency = ((try? c.decodeIfPresent(String.self, forKey: .currency)) ?? nil)?.uppercased() ?? "RUB"
            owedToMe = ((try? c.decodeIfPresent(Int64.self, forKey: .owedToMe)) ?? nil) ?? 0
            iOwe = ((try? c.decodeIfPresent(Int64.self, forKey: .iOwe)) ?? nil) ?? 0
            openCount = ((try? c.decodeIfPresent(Int.self, forKey: .openCount)) ?? nil) ?? 0
        }
    }

    let version: Int
    /// The caller's local date on the server ("yyyy-MM-dd").
    let today: String?
    let debts: [Entry]
    let totals: [Total]

    enum CodingKeys: String, CodingKey { case version, today, debts, totals }

    init(version: Int = 1, today: String? = nil, debts: [Entry], totals: [Total] = []) {
        self.version = version; self.today = today; self.debts = debts; self.totals = totals
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = ((try? c.decodeIfPresent(Int.self, forKey: .version)) ?? nil) ?? 1
        today = ((try? c.decodeIfPresent(String.self, forKey: .today)) ?? nil).map { String($0.prefix(10)) }
        debts = Self.lossy(c, .debts)
        totals = Self.lossy(c, .totals)
    }

    /// Decodes an array element by element, dropping only the elements that
    /// fail — one malformed row must not hide every other debt.
    private static func lossy<T: Decodable>(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [T] {
        guard var array = try? c.nestedUnkeyedContainer(forKey: key) else { return [] }
        var out: [T] = []
        while !array.isAtEnd {
            if let value = try? array.decode(T.self) {
                out.append(value)
            } else {
                _ = try? array.decode(Discard.self)
            }
        }
        return out
    }

    /// Accepts any JSON value, so a failed element is skipped instead of
    /// stalling the container.
    private struct Discard: Decodable {
        init(from decoder: Decoder) throws {}
    }
}
