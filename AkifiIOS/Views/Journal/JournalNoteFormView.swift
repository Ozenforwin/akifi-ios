import SwiftUI
import PhotosUI

struct JournalNoteFormView: View {
    let viewModel: JournalViewModel
    var editingNote: FinancialNote?
    var preselectedTransactionId: String?

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var content = ""
    @State private var selectedMood: NoteMood?
    @State private var tagInput = ""
    @State private var tags: [String] = []
    @State private var noteType: NoteType = .freeform
    @State private var selectedTransactionId: String?
    @State private var isSaving = false
    @State private var error: String?
    @State private var selectedPhotos: [PhotosPickerItem] = []

    private var isEditing: Bool { editingNote != nil }

    var body: some View {
        NavigationStack {
            Form {
                noteTypeSection
                contentSection
                moodSection
                tagsSection
                transactionSection
                photoSection
            }
            .navigationTitle(isEditing ? String(localized: "journal.editNote") : String(localized: "journal.newNote"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "action.save")) {
                        Task { await save() }
                    }
                    .disabled(content.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                    .fontWeight(.semibold)
                }
            }
            .alert("Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") {}
            } message: {
                Text(error ?? "")
            }
            .onAppear { populateFromEditing() }
        }
    }

    // MARK: - Sections

    private var noteTypeSection: some View {
        Section {
            Picker(String(localized: "journal.noteType"), selection: $noteType) {
                ForEach([NoteType.freeform, .transaction], id: \.self) { type in
                    Label(type.localizedName, systemImage: type.icon).tag(type)
                }
            }
            .pickerStyle(.segmented)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }

    private var contentSection: some View {
        Section(String(localized: "journal.content")) {
            TextField(String(localized: "journal.titlePlaceholder"), text: $title)
            TextEditor(text: $content)
                .frame(minHeight: 120)
                .overlay(alignment: .topLeading) {
                    if content.isEmpty {
                        Text(String(localized: "journal.contentPlaceholder"))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private var moodSection: some View {
        Section(String(localized: "journal.mood")) {
            HStack(spacing: 12) {
                ForEach(NoteMood.allCases, id: \.self) { mood in
                    Button {
                        if selectedMood == mood {
                            selectedMood = nil
                        } else {
                            selectedMood = mood
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Text(mood.emoji)
                                .font(.title2)
                            Text(mood.localizedName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(selectedMood == mood ? Color.accentColor.opacity(0.15) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(selectedMood == mood ? Color.accentColor : Color.clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var tagsSection: some View {
        Section(String(localized: "journal.tags")) {
            HStack {
                TextField(String(localized: "journal.tagPlaceholder"), text: $tagInput)
                    .textInputAutocapitalization(.never)
                    .onSubmit { addTag() }
                Button {
                    addTag()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.accent)
                }
                .disabled(tagInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text("#\(tag)")
                                .font(.caption.weight(.medium))
                            Button {
                                tags.removeAll { $0 == tag }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                            }
                        }
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.purple.opacity(0.1)))
                    }
                }
            }

            if !viewModel.allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(viewModel.allTags.filter { !tags.contains($0) }, id: \.self) { tag in
                            Button {
                                tags.append(tag)
                            } label: {
                                Text("#\(tag)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color(.quaternarySystemFill)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var transactionSection: some View {
        Group {
            if noteType == .transaction || preselectedTransactionId != nil {
                Section(String(localized: "journal.linkedTransaction")) {
                    if let txId = selectedTransactionId ?? preselectedTransactionId {
                        HStack {
                            Image(systemName: "link")
                                .foregroundStyle(.blue)
                            Text(String(localized: "journal.transactionLinked"))
                                .font(.subheadline)
                            Spacer()
                            Button {
                                selectedTransactionId = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text(String(localized: "journal.selectTransaction"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var photoSection: some View {
        Section(String(localized: "journal.photos")) {
            PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 3, matching: .images) {
                Label(String(localized: "journal.addPhotos"), systemImage: "photo.badge.plus")
            }
            if !selectedPhotos.isEmpty {
                Text(String(localized: "journal.photosSelected \(selectedPhotos.count)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func addTag() {
        let tag = tagInput.trimmingCharacters(in: .whitespaces).lowercased()
        guard !tag.isEmpty, !tags.contains(tag) else { return }
        tags.append(tag)
        tagInput = ""
    }

    private func save() async {
        isSaving = true
        do {
            if let editing = editingNote {
                try await viewModel.updateNote(
                    id: editing.id,
                    title: title.isEmpty ? nil : title,
                    content: content,
                    tags: tags.isEmpty ? nil : tags,
                    mood: selectedMood
                )
            } else {
                _ = try await viewModel.createNote(
                    title: title.isEmpty ? nil : title,
                    content: content,
                    transactionId: selectedTransactionId ?? preselectedTransactionId,
                    tags: tags.isEmpty ? nil : tags,
                    mood: selectedMood,
                    noteType: preselectedTransactionId != nil ? .transaction : noteType
                )
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isSaving = false
    }

    private func populateFromEditing() {
        guard let note = editingNote else { return }
        title = note.title ?? ""
        content = note.content
        selectedMood = note.mood
        tags = note.tags ?? []
        noteType = note.noteType
        selectedTransactionId = note.transactionId
    }
}
