import Foundation

enum NoteMood: String, Codable, Sendable, CaseIterable {
    case great, good, neutral, worried, stressed

    var emoji: String {
        switch self {
        case .great: "😊"
        case .good: "🙂"
        case .neutral: "😐"
        case .worried: "😟"
        case .stressed: "😫"
        }
    }

    var localizedName: String {
        switch self {
        case .great: String(localized: "mood.great")
        case .good: String(localized: "mood.good")
        case .neutral: String(localized: "mood.neutral")
        case .worried: String(localized: "mood.worried")
        case .stressed: String(localized: "mood.stressed")
        }
    }
}

enum NoteType: String, Codable, Sendable, CaseIterable {
    case transaction
    case reflection
    case freeform

    var localizedName: String {
        switch self {
        case .transaction: String(localized: "noteType.transaction")
        case .reflection: String(localized: "noteType.reflection")
        case .freeform: String(localized: "noteType.freeform")
        }
    }

    var icon: String {
        switch self {
        case .transaction: "arrow.left.arrow.right"
        case .reflection: "brain.head.profile"
        case .freeform: "note.text"
        }
    }
}

struct FinancialNote: Codable, Identifiable, Sendable {
    let id: String
    let userId: String
    var title: String?
    var content: String
    var transactionId: String?
    var tags: [String]?
    var mood: NoteMood?
    var photoUrls: [String]?
    var noteType: NoteType
    var periodStart: String?
    var periodEnd: String?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title, content
        case transactionId = "transaction_id"
        case tags, mood
        case photoUrls = "photo_urls"
        case noteType = "note_type"
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(id: String, userId: String, title: String? = nil, content: String, transactionId: String? = nil, tags: [String]? = nil, mood: NoteMood? = nil, photoUrls: [String]? = nil, noteType: NoteType = .freeform, periodStart: String? = nil, periodEnd: String? = nil, createdAt: String? = nil, updatedAt: String? = nil) {
        self.id = id; self.userId = userId; self.title = title; self.content = content
        self.transactionId = transactionId; self.tags = tags; self.mood = mood
        self.photoUrls = photoUrls; self.noteType = noteType
        self.periodStart = periodStart; self.periodEnd = periodEnd
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    var displayDate: String {
        guard let createdAt else { return "" }
        return String(createdAt.prefix(10))
    }
}
