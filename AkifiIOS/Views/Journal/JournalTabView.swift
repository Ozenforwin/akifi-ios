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
            VStack(spacing: 0) {
                filterBar
                notesList
            }
            .navigationTitle(String(localized: "journal.title"))
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Text(String(localized: "journal.title"))
                            .font(.headline)
                        Text("BETA")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.purple.opacity(0.15)))
                            .foregroundStyle(.purple)
                    }
                }
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
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                }
            }
            .searchable(text: $searchText, prompt: String(localized: "journal.search"))
            .onChange(of: searchText) { _, newValue in
                viewModel.searchText = newValue
                Task { await viewModel.search() }
            }
            .sheet(isPresented: $showNoteForm) {
                JournalNoteFormView(viewModel: viewModel, initialType: .note)
                    .presentationBackground(.regularMaterial)
            }
            .sheet(isPresented: $showReflectionForm) {
                JournalNoteFormView(viewModel: viewModel, initialType: .reflection)
                    .presentationBackground(.regularMaterial)
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

    private var filterBar: some View {
        let allTags = viewModel.tagsByFrequency
        let visibleTags = Array(allTags.prefix(Self.visibleTagLimit))
        let overflowCount = max(0, allTags.count - visibleTags.count)

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(JournalViewModel.NoteFilter.allCases, id: \.self) { filter in
                    // Reuse shared FilterChip for visual consistency (R2.9).
                    FilterChip(
                        title: filter.localizedName,
                        isSelected: viewModel.selectedFilter == filter
                    ) {
                        viewModel.selectedFilter = filter
                        viewModel.refilter()
                    }
                }

                if !allTags.isEmpty {
                    Divider().frame(height: 20)

                    ForEach(visibleTags, id: \.self) { tag in
                        tagChip(tag)
                    }

                    if overflowCount > 0 {
                        Button {
                            showTagSheet = true
                        } label: {
                            Text("+\(overflowCount)")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color(.quaternarySystemFill)))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(String(localized: "journal.tags.moreButton \(overflowCount)")))
                    }
                }

                // Small trailing spacer so the last chip always has breathing
                // room from the fade mask (avoids clipping — BUG-004).
                Color.clear.frame(width: 12, height: 1)
            }
            .padding(.leading, 16)
            .padding(.vertical, 8)
        }
        .mask(
            HStack(spacing: 0) {
                Color.black
                LinearGradient(
                    colors: [.black, .black.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 24)
            }
        )
    }

    private func tagChip(_ tag: String) -> some View {
        let isSelected = viewModel.selectedTag == tag
        return Button {
            if isSelected {
                viewModel.selectedTag = nil
            } else {
                viewModel.selectedTag = tag
            }
            viewModel.refilter()
        } label: {
            Text("#\(tag)")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(isSelected
                        ? Color.budget.opacity(0.15)
                        : Color(.quaternarySystemFill))
                )
                .foregroundStyle(isSelected ? Color.budget : .secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Notes List

    private var notesList: some View {
        Group {
            if !viewModel.hasLoadedOnce && viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.filteredNotes.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
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
                                HStack {
                                    Text(formatSectionDate(group.date))
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 20)
                                .padding(.bottom, 6)
                            }
                        }

                        if viewModel.filteredNotes.count >= 50 {
                            ProgressView()
                                .padding()
                                .task { await viewModel.loadMore() }
                        }
                    }
                    .padding(.bottom, 100)
                }
            }
        }
    }

    // MARK: - Empty State (spec R2.2)

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.accent.opacity(0.08))
                    .frame(width: 80, height: 80)
                Image(systemName: "text.book.closed")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accent)
            }
            VStack(spacing: 8) {
                Text(String(localized: "journal.empty.title"))
                    .font(.title3.weight(.semibold))
                Text(String(localized: "journal.empty.subtitle"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Button {
                showNoteForm = true
            } label: {
                Label(String(localized: "journal.empty.writeNote"), systemImage: "pencil")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: 280)

            Button {
                showReflectionForm = true
            } label: {
                Text(String(localized: "journal.empty.reflection"))
                    .font(.subheadline)
                    .foregroundStyle(Color.budget)
            }
            .buttonStyle(.plain)
            .padding(.top, -8)

            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private func formatSectionDate(_ dateStr: String) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        guard let date = df.date(from: dateStr) else { return dateStr }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "date.today") }
        if calendar.isDateInYesterday(date) { return String(localized: "date.yesterday") }

        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .none
        return display.string(from: date)
    }
}
