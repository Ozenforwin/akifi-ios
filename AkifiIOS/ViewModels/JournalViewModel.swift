import Foundation

@Observable @MainActor
final class JournalViewModel {
    var notes: [FinancialNote] = []
    var filteredNotes: [FinancialNote] = []
    var isLoading = false
    var hasLoadedOnce = false
    var error: String?
    var searchText = ""
    var selectedFilter: NoteFilter = .all
    var allTags: [String] = []
    var selectedTag: String?

    private let repo = FinancialNoteRepository()
    private var hasMorePages = true
    private var currentOffset = 0
    private let pageSize = 50
    private var lastLoadedAt: Date?
    private let cacheTTL: TimeInterval = 60

    /// Tags that the user has asked to hide from the suggestion list. Stored
    /// in UserDefaults so the preference survives app relaunches. Historical
    /// notes keep the tag verbatim — only the suggestion surfaces are pruned
    /// (see spec R2.5 — user-friendly choice).
    private let hiddenTagsKey = "journal.hiddenTags.v1"
    private(set) var hiddenTags: Set<String> = {
        let raw = UserDefaults.standard.stringArray(forKey: "journal.hiddenTags.v1") ?? []
        return Set(raw)
    }()

    /// v2: user-facing 2-type filter. `.notes` merges legacy `.freeform` + `.transaction`.
    enum NoteFilter: CaseIterable, Hashable {
        case all, notes, reflections

        var localizedName: String {
            switch self {
            case .all: String(localized: "journal.filter.all")
            case .notes: String(localized: "journal.filter.notes")
            case .reflections: String(localized: "journal.filter.reflections")
            }
        }

        /// Types matched by this filter. `nil` = no filter.
        var matchingTypes: [NoteType]? {
            switch self {
            case .all: nil
            case .notes: [.freeform, .transaction]
            case .reflections: [.reflection]
            }
        }
    }

    /// Load initial data, respecting the cache TTL if already loaded.
    /// Pull-to-refresh callers should use `loadInitial(force: true)`.
    func loadInitialIfNeeded() async {
        if hasLoadedOnce, let lastLoadedAt, Date().timeIntervalSince(lastLoadedAt) < cacheTTL {
            return
        }
        await loadInitial()
    }

    func loadInitial(force: Bool = false) async {
        // Only show full-screen spinner on very first load.
        if !hasLoadedOnce { isLoading = true }
        error = nil
        currentOffset = 0
        hasMorePages = true

        do {
            // fetchAll currently does not support an IN filter, so we fetch all
            // and filter client-side when `selectedFilter` groups multiple types.
            notes = try await repo.fetchAll(limit: pageSize, offset: 0, noteType: nil)
            let fetchedTags = try await repo.fetchAllTags()
            allTags = fetchedTags.filter { !hiddenTags.contains($0) }
            applyFilters()
            hasLoadedOnce = true
            lastLoadedAt = Date()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func loadMore() async {
        guard hasMorePages, !isLoading else { return }
        currentOffset += pageSize

        do {
            let newNotes = try await repo.fetchAll(limit: pageSize, offset: currentOffset, noteType: nil)
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

    func createNote(title: String?, content: String, transactionId: String? = nil, tags: [String]? = nil, mood: NoteMood? = nil, photoUrls: [String]? = nil, noteType: NoteType = .freeform, periodStart: String? = nil, periodEnd: String? = nil, noteId: String? = nil) async throws -> FinancialNote {
        let userId = try await SupabaseManager.shared.currentUserId()
        let input = CreateNoteInput(
            id: noteId,
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
        if photoUrls?.isEmpty == false {
            AnalyticsService.logEvent("journal_photo_attached", params: ["count": photoUrls!.count])
        }
        if transactionId != nil {
            AnalyticsService.logEvent("journal_transaction_linked", params: nil)
        }
        if mood != nil {
            AnalyticsService.logEvent("journal_mood_set", params: ["mood": mood!.rawValue])
        }
        if noteType == .reflection {
            AnalyticsService.logEvent("journal_reflection_completed", params: nil)
        }
        return note
    }

    func updateNote(id: String, title: String? = nil, content: String? = nil, transactionId: String?? = nil, tags: [String]? = nil, mood: NoteMood? = nil, photoUrls: [String]? = nil, periodStart: String?? = nil, periodEnd: String?? = nil) async throws {
        let input = UpdateNoteInput(
            title: title,
            content: content,
            transaction_id: transactionId,
            tags: tags,
            mood: mood?.rawValue,
            photo_urls: photoUrls,
            period_start: periodStart,
            period_end: periodEnd
        )
        try await repo.update(id: id, input)
        if let idx = notes.firstIndex(where: { $0.id == id }) {
            var note = notes[idx]
            if let title { note.title = title }
            if let content { note.content = content }
            if let transactionId { note.transactionId = transactionId }
            if let tags { note.tags = tags }
            if let mood { note.mood = mood }
            if let photoUrls { note.photoUrls = photoUrls }
            if let periodStart { note.periodStart = periodStart }
            if let periodEnd { note.periodEnd = periodEnd }
            notes[idx] = note
            applyFilters()
        }
        if let newTags = tags {
            for tag in newTags where !allTags.contains(tag) {
                allTags.append(tag)
            }
            allTags.sort()
        }
    }

    func deleteNote(_ note: FinancialNote) async {
        do {
            try await repo.delete(id: note.id)
            notes.removeAll { $0.id == note.id }
            applyFilters()
            // Best-effort: remove attached photos from Storage.
            if let urls = note.photoUrls {
                for url in urls {
                    await JournalPhotoUploader.delete(publicURL: url)
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func notesForTransaction(_ transactionId: String) async -> [FinancialNote] {
        (try? await repo.fetchByTransaction(transactionId: transactionId)) ?? []
    }

    private func applyFilters() {
        var result = notes

        if let matchingTypes = selectedFilter.matchingTypes {
            result = result.filter { matchingTypes.contains($0.noteType) }
        }

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

    /// Tags ordered by usage frequency (most used first), de-duplicated.
    /// Hidden tags (user-deleted via context menu or Tag Management) are
    /// excluded from suggestion surfaces even when existing notes still
    /// reference them.
    var tagsByFrequency: [String] {
        var counts: [String: Int] = [:]
        for note in notes {
            for tag in note.tags ?? [] {
                counts[tag, default: 0] += 1
            }
        }
        return counts
            .filter { !hiddenTags.contains($0.key) }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .map(\.key)
    }

    /// Re-apply filters when `selectedFilter` / `selectedTag` change, without
    /// hitting the network.
    func refilter() {
        applyFilters()
    }

    // MARK: - Tag history management (spec R2.5)

    /// Hide a tag from all suggestion surfaces without mutating existing notes.
    /// Historical notes retain the tag verbatim so the user's record of the past
    /// is preserved. The preference is persisted in UserDefaults.
    func hideTagFromHistory(_ tag: String) {
        guard !tag.isEmpty else { return }
        hiddenTags.insert(tag)
        allTags.removeAll { $0 == tag }
        if selectedTag == tag {
            selectedTag = nil
            applyFilters()
        }
        UserDefaults.standard.set(Array(hiddenTags), forKey: hiddenTagsKey)
    }

    /// Restore a previously hidden tag. Exposed for the Tag Management screen.
    func restoreHiddenTag(_ tag: String) {
        hiddenTags.remove(tag)
        UserDefaults.standard.set(Array(hiddenTags), forKey: hiddenTagsKey)
    }

    /// Count how many notes reference a given tag. Used by the Tag Management
    /// screen to show usage stats (spec R2.5 Surface 2).
    func tagUsageCount(_ tag: String) -> Int {
        notes.reduce(0) { acc, note in
            acc + ((note.tags ?? []).filter { $0 == tag }.count)
        }
    }
}
