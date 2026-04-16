import Foundation

@Observable @MainActor
final class JournalViewModel {
    var notes: [FinancialNote] = []
    var filteredNotes: [FinancialNote] = []
    var isLoading = false
    var error: String?
    var searchText = ""
    var selectedFilter: NoteFilter = .all
    var allTags: [String] = []
    var selectedTag: String?

    private let repo = FinancialNoteRepository()
    private var hasMorePages = true
    private var currentOffset = 0
    private let pageSize = 50

    enum NoteFilter: CaseIterable {
        case all, transaction, reflection, freeform

        var localizedName: String {
            switch self {
            case .all: String(localized: "journal.filter.all")
            case .transaction: String(localized: "journal.filter.transactions")
            case .reflection: String(localized: "journal.filter.reflections")
            case .freeform: String(localized: "journal.filter.freeform")
            }
        }

        var noteType: NoteType? {
            switch self {
            case .all: nil
            case .transaction: .transaction
            case .reflection: .reflection
            case .freeform: .freeform
            }
        }
    }

    func loadInitial() async {
        isLoading = true
        error = nil
        currentOffset = 0
        hasMorePages = true

        do {
            notes = try await repo.fetchAll(limit: pageSize, offset: 0, noteType: selectedFilter.noteType)
            allTags = try await repo.fetchAllTags()
            applyFilters()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func loadMore() async {
        guard hasMorePages, !isLoading else { return }
        currentOffset += pageSize

        do {
            let newNotes = try await repo.fetchAll(limit: pageSize, offset: currentOffset, noteType: selectedFilter.noteType)
            if newNotes.count < pageSize { hasMorePages = false }
            notes.append(contentsOf: newNotes)
            applyFilters()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func search() async {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            applyFilters()
            return
        }
        isLoading = true
        do {
            notes = try await repo.search(query: searchText)
            applyFilters()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func createNote(title: String?, content: String, transactionId: String? = nil, tags: [String]? = nil, mood: NoteMood? = nil, photoUrls: [String]? = nil, noteType: NoteType = .freeform, periodStart: String? = nil, periodEnd: String? = nil) async throws -> FinancialNote {
        let userId = try await SupabaseManager.shared.currentUserId()
        let input = CreateNoteInput(
            user_id: userId,
            title: title,
            content: content,
            transaction_id: transactionId,
            tags: tags,
            mood: mood?.rawValue,
            photo_urls: photoUrls,
            note_type: noteType.rawValue,
            period_start: periodStart,
            period_end: periodEnd
        )
        let note = try await repo.create(input)
        notes.insert(note, at: 0)
        applyFilters()
        if let newTags = tags {
            for tag in newTags where !allTags.contains(tag) {
                allTags.append(tag)
            }
            allTags.sort()
        }
        AnalyticsService.logEvent("journal_note_created", params: ["type": noteType.rawValue])
        return note
    }

    func updateNote(id: String, title: String? = nil, content: String? = nil, tags: [String]? = nil, mood: NoteMood? = nil, photoUrls: [String]? = nil) async throws {
        let input = UpdateNoteInput(
            title: title,
            content: content,
            tags: tags,
            mood: mood?.rawValue,
            photo_urls: photoUrls
        )
        try await repo.update(id: id, input)
        if let idx = notes.firstIndex(where: { $0.id == id }) {
            var note = notes[idx]
            if let title { note.title = title }
            if let content { note.content = content }
            if let tags { note.tags = tags }
            if let mood { note.mood = mood }
            if let photoUrls { note.photoUrls = photoUrls }
            notes[idx] = note
            applyFilters()
        }
    }

    func deleteNote(_ note: FinancialNote) async {
        do {
            try await repo.delete(id: note.id)
            notes.removeAll { $0.id == note.id }
            applyFilters()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func notesForTransaction(_ transactionId: String) async -> [FinancialNote] {
        (try? await repo.fetchByTransaction(transactionId: transactionId)) ?? []
    }

    private func applyFilters() {
        var result = notes

        if let tag = selectedTag {
            result = result.filter { $0.tags?.contains(tag) == true }
        }

        filteredNotes = result
    }

    // MARK: - Grouped by date

    var groupedByDate: [(date: String, notes: [FinancialNote])] {
        let grouped = Dictionary(grouping: filteredNotes) { $0.displayDate }
        return grouped
            .map { (date: $0.key, notes: $0.value) }
            .sorted { $0.date > $1.date }
    }
}
