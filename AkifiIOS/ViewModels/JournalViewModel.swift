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

    /// Results of the current search; nil while no search is active. Kept
    /// apart from `notes`, the paged feed (V6): `search()` used to REPLACE
    /// the feed — of 120 notes, the 3 matching "кофе" were all that was
    /// left after clearing the search, and scrolling appended the old
    /// cursor's second page to them.
    private(set) var searchResults: [FinancialNote]?

    /// The in-flight (debounced) search. Each keystroke cancels it; a
    /// response for an older query is dropped instead of landing after
    /// the newer one.
    @ObservationIgnored private(set) var searchTask: Task<Void, Never>?
    @ObservationIgnored private let searchNotes: @Sendable (String) async throws -> [FinancialNote]
    @ObservationIgnored private let searchDebounce: Duration

    /// `searchNotes` / `searchDebounce` are injectable for tests.
    init(
        searchNotes: (@Sendable (String) async throws -> [FinancialNote])? = nil,
        searchDebounce: Duration = .milliseconds(300)
    ) {
        self.searchNotes = searchNotes ?? { try await FinancialNoteRepository().search(query: $0) }
        self.searchDebounce = searchDebounce
    }

    /// The feed can page further: not while showing search results (they
    /// are complete), and only while the server has more. The list's
    /// "load more" sentinel follows this — not "50 notes are visible",
    /// which hid older notes whenever a type/tag filter matched fewer than
    /// 50 of the loaded ones.
    var canLoadMore: Bool { searchResults == nil && hasMorePages }

    private var hasMorePages = true
    /// Keyset position: the last note of the last page fetched (Y12).
    private var pageCursor: FinancialNoteRepository.PageCursor?
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
        hasMorePages = true

        do {
            // The page fetch has no IN filter, so we fetch all types and
            // filter client-side when `selectedFilter` groups multiple types.
            let firstPage = try await repo.fetchPage(limit: pageSize, after: nil)
            notes = firstPage
            pageCursor = Self.cursor(after: firstPage)
            hasMorePages = firstPage.count == pageSize
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
        guard hasMorePages, !isLoading, !isLoadingMore, let cursor = pageCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let newNotes = try await repo.fetchPage(limit: pageSize, after: cursor)
            // A reload replaced the feed while this page was in flight.
            guard pageCursor == cursor else { return }
            if newNotes.count < pageSize { hasMorePages = false }
            notes = Self.appendingPage(newNotes, to: notes)
            pageCursor = Self.cursor(after: newNotes) ?? cursor
            applyFilters()
        } catch {
            // The sentinel scrolled away mid-request — not a failure.
            if Task.isCancelled { return }
            self.error = error.localizedDescription
        }
    }

    @ObservationIgnored private var isLoadingMore = false

    /// Cursor after `page` (its last row), nil for an empty page or a row
    /// without `created_at`.
    static func cursor(after page: [FinancialNote]) -> FinancialNoteRepository.PageCursor? {
        guard let last = page.last, let createdAt = last.createdAt else { return nil }
        return FinancialNoteRepository.PageCursor(createdAt: createdAt, id: last.id)
    }

    /// Appends a page, skipping notes already in the list (a note created
    /// locally on this device is inserted at the top before any page has
    /// reached it). Pure for unit testing.
    static func appendingPage(_ page: [FinancialNote], to notes: [FinancialNote]) -> [FinancialNote] {
        let known = Set(notes.map(\.id))
        return notes + page.filter { !known.contains($0.id) }
    }

    /// Sign-out: nothing of the previous user's journal may survive into
    /// the next session (the view-model lives as long as the app).
    func reset() {
        notes = []
        filteredNotes = []
        isLoading = false
        hasLoadedOnce = false
        error = nil
        searchText = ""
        selectedFilter = .all
        allTags = []
        selectedTag = nil
        hasMorePages = true
        pageCursor = nil
        lastLoadedAt = nil
        searchTask?.cancel()
        searchTask = nil
        searchResults = nil
    }

    /// The search field changed. Debounced; the feed (`notes`) is never
    /// touched — clearing the field shows it again as it was.
    func updateSearch(_ text: String) {
        searchText = text
        searchTask?.cancel()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchTask = nil
            searchResults = nil
            applyFilters()
            return
        }
        let searchNotes = searchNotes
        let debounce = searchDebounce
        searchTask = Task { [weak self] in
            if debounce > .zero {
                do { try await Task.sleep(for: debounce) } catch { return }
            }
            do {
                let results = try await searchNotes(query)
                guard !Task.isCancelled, let self else { return }
                self.searchResults = results
                self.applyFilters()
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), let self else { return }
                self.error = error.localizedDescription
            }
        }
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
        // A new note may match the active search — re-run it.
        if searchResults != nil { updateSearch(searchText) }
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

    /// `mood` is double-optional (V4): `.some(nil)` clears the mood; a plain
    /// optional dropped the key and a deselected mood stayed on the server.
    func updateNote(id: String, title: String? = nil, content: String? = nil, transactionId: String?? = nil, tags: [String]? = nil, mood: NoteMood?? = nil, photoUrls: [String]? = nil, periodStart: String?? = nil, periodEnd: String?? = nil) async throws {
        let input = UpdateNoteInput(
            title: title,
            content: content,
            transaction_id: transactionId,
            tags: tags,
            mood: mood.map { $0?.rawValue },
            photo_urls: photoUrls,
            period_start: periodStart,
            period_end: periodEnd
        )
        try await repo.update(id: id, input)
        func patched(_ original: FinancialNote) -> FinancialNote {
            var note = original
            if let title { note.title = title }
            if let content { note.content = content }
            if let transactionId { note.transactionId = transactionId }
            if let tags { note.tags = tags }
            if let mood { note.mood = mood }
            if let photoUrls { note.photoUrls = photoUrls }
            if let periodStart { note.periodStart = periodStart }
            if let periodEnd { note.periodEnd = periodEnd }
            return note
        }
        if let idx = notes.firstIndex(where: { $0.id == id }) {
            notes[idx] = patched(notes[idx])
        }
        if let idx = searchResults?.firstIndex(where: { $0.id == id }) {
            searchResults?[idx] = patched(searchResults![idx])
        }
        applyFilters()
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
            searchResults?.removeAll { $0.id == note.id }
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
        var result = searchResults ?? notes

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
