import SwiftUI

struct JournalTabView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var showNoteForm = false
    @State private var showReflectionForm = false
    @State private var showTagSheet = false
    @State private var searchText = ""

    private var viewModel: JournalViewModel { appViewModel.journalViewModel }
    private static let visibleTagLimit = 5

    var body: some View {
        NavigationStack {
            notesList
                .background(Color(.systemGroupedBackground))
                .navigationTitle(String(localized: "journal.title"))
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                showNoteForm = true
                            } label: {
                                Label(String(localized: "journal.newNote"), systemImage: "note.text.badge.plus")
                            }
                            Button {
                                showReflectionForm = true
                            } label: {
                                Label(String(localized: "journal.newReflection"), systemImage: "brain.head.profile")
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(String(localized: "common.add"))
                    }
                }
                .searchable(text: $searchText, prompt: String(localized: "journal.search"))
                .onChange(of: searchText) { _, newValue in
                    // Debounced, cancels the previous query, leaves the feed
                    // alone (V6).
                    viewModel.updateSearch(newValue)
                }
                .sheet(isPresented: $showNoteForm) {
                    JournalNoteFormView(viewModel: viewModel, initialType: .note)
                }
                .sheet(isPresented: $showReflectionForm) {
                    JournalNoteFormView(viewModel: viewModel, initialType: .reflection)
                }
                .sheet(isPresented: $showTagSheet) {
                    TagFilterSheet(viewModel: viewModel)
                }
                .refreshable {
                    await viewModel.loadInitial(force: true)
                }
                .task {
                    await viewModel.loadInitialIfNeeded()
                }
        }
    }

    // MARK: - Filter Bar (spec R2.3)

    /// Type filter as a system segmented control, tags as a chip row
    /// below it. Scrolls with the notes — no sticky header under the bar.
    private var filterBar: some View {
        let allTags = viewModel.tagsByFrequency
        let visibleTags = Array(allTags.prefix(Self.visibleTagLimit))
        let overflowCount = max(0, allTags.count - visibleTags.count)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker(
                    String(localized: "journal.title"),
                    selection: Binding(
                        get: { viewModel.selectedFilter },
                        set: { filter in
                            viewModel.selectedFilter = filter
                            viewModel.refilter()
                        }
                    )
                ) {
                    ForEach(JournalViewModel.NoteFilter.allCases, id: \.self) { filter in
                        Text(filter.localizedName).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(verbatim: "BETA")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.budget.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.budget)
            }
            .padding(.horizontal, 16)

            if !allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(visibleTags, id: \.self) { tag in
                            tagChip(tag)
                        }

                        if overflowCount > 0 {
                            FilterChip(title: "+\(overflowCount)", isSelected: false) {
                                showTagSheet = true
                            }
                            .accessibilityLabel(Text(String(localized: "journal.tags.moreButton \(overflowCount)")))
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func tagChip(_ tag: String) -> some View {
        let isSelected = viewModel.selectedTag == tag
        return FilterChip(title: "#\(tag)", isSelected: isSelected) {
            if isSelected {
                viewModel.selectedTag = nil
            } else {
                viewModel.selectedTag = tag
            }
            viewModel.refilter()
        }
    }

    // MARK: - Notes List

    private var notesList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                filterBar

                if !viewModel.hasLoadedOnce && viewModel.isLoading {
                    ProgressView()
                        .padding(.top, 80)
                } else if viewModel.filteredNotes.isEmpty {
                    emptyState
                        .padding(.top, 24)
                } else {
                    ForEach(viewModel.groupedByDate, id: \.date) { group in
                        Section {
                            ForEach(group.notes) { note in
                                NavigationLink {
                                    JournalNoteDetailView(note: note, viewModel: viewModel, dataStore: appViewModel.dataStore)
                                } label: {
                                    JournalNoteCardView(note: note, dataStore: appViewModel.dataStore)
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Text(formatSectionDate(group.date))
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.top, 16)
                                .padding(.bottom, 6)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }

                    if viewModel.canLoadMore {
                        ProgressView()
                            .padding()
                            // Re-fires after each page (the id changes),
                            // so a filter that matches few notes keeps
                            // paging until the screen fills or the feed
                            // ends.
                            .task(id: viewModel.notes.count) { await viewModel.loadMore() }
                    }
                }
            }
        }
        .akifiFloatingButtonClearance()
    }

    // MARK: - Empty State (spec R2.2)

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "journal.empty.title"), systemImage: "text.book.closed")
        } description: {
            Text(String(localized: "journal.empty.subtitle"))
        } actions: {
            Button {
                showNoteForm = true
            } label: {
                Label(String(localized: "journal.empty.writeNote"), systemImage: "pencil")
            }
            .buttonStyle(.akifiPrimary)

            Button(String(localized: "journal.empty.reflection")) {
                showReflectionForm = true
            }
            .buttonStyle(.borderless)
        }
    }

    private func formatSectionDate(_ dateStr: String) -> String {
        guard let date = AppDateFormatters.isoDate.date(from: dateStr) else { return dateStr }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "date.today") }
        if calendar.isDateInYesterday(date) { return String(localized: "date.yesterday") }

        return AppDateFormatters.displayDate.string(from: date)
    }
}
