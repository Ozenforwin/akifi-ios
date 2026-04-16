import SwiftUI

struct JournalTabView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = JournalViewModel()
    @State private var showNoteForm = false
    @State private var showReflectionForm = false
    @State private var searchText = ""
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                notesList
            }
            .navigationTitle(String(localized: "journal.title"))
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
                JournalNoteFormView(viewModel: viewModel)
                    .presentationBackground(.ultraThinMaterial)
            }
            .sheet(isPresented: $showReflectionForm) {
                JournalReflectionFormView(viewModel: viewModel, dataStore: appViewModel.dataStore)
                    .presentationBackground(.ultraThinMaterial)
            }
            .task { await viewModel.loadInitial() }
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(JournalViewModel.NoteFilter.allCases, id: \.self) { filter in
                    Button {
                        viewModel.selectedFilter = filter
                        Task { await viewModel.loadInitial() }
                    } label: {
                        Text(filter.localizedName)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(viewModel.selectedFilter == filter
                                    ? Color.accentColor : Color(.tertiarySystemFill))
                            )
                            .foregroundStyle(viewModel.selectedFilter == filter ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }

                if !viewModel.allTags.isEmpty {
                    Divider().frame(height: 20)

                    ForEach(viewModel.allTags, id: \.self) { tag in
                        Button {
                            if viewModel.selectedTag == tag {
                                viewModel.selectedTag = nil
                            } else {
                                viewModel.selectedTag = tag
                            }
                            Task { await viewModel.loadInitial() }
                        } label: {
                            Text("#\(tag)")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule().fill(viewModel.selectedTag == tag
                                        ? Color.purple.opacity(0.2) : Color(.quaternarySystemFill))
                                )
                                .foregroundStyle(viewModel.selectedTag == tag ? .purple : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Notes List

    private var notesList: some View {
        Group {
            if viewModel.isLoading && viewModel.notes.isEmpty {
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
                                .padding(.top, 16)
                                .padding(.bottom, 4)
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

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "book.closed")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(String(localized: "journal.empty.title"))
                .font(.headline)
            Text(String(localized: "journal.empty.subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                showNoteForm = true
            } label: {
                Label(String(localized: "journal.empty.action"), systemImage: "plus")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
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
