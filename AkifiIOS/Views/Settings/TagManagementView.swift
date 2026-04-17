import SwiftUI

/// Settings screen for bulk management of journal tag history (spec R2.5
/// Surface 2). Swipe-to-delete hides a tag from all suggestion surfaces.
/// Existing notes retain their tags verbatim — the action is reversible by
/// creating a new note with the tag or by restoring from Hidden Tags below.
struct TagManagementView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var pendingDeleteTag: String?
    @State private var showDeleteConfirm = false

    private var viewModel: JournalViewModel { appViewModel.journalViewModel }

    var body: some View {
        List {
            if viewModel.allTags.isEmpty && viewModel.hiddenTags.isEmpty {
                Section {
                    Text(String(localized: "journal.tagManagement.empty"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                }
            }

            if !viewModel.allTags.isEmpty {
                Section(String(localized: "journal.tagManagement.activeTags")) {
                    ForEach(viewModel.allTags, id: \.self) { tag in
                        HStack {
                            Text("#\(tag)")
                                .font(.body)
                                .minimumScaleFactor(0.85)
                                .lineLimit(1)
                            Spacer()
                            let count = viewModel.tagUsageCount(tag)
                            Text(
                                String(
                                    format: String(localized: "journal.tagManagement.usageCount %lld"),
                                    count
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeleteTag = tag
                                showDeleteConfirm = true
                            } label: {
                                Label(String(localized: "action.delete"), systemImage: "trash")
                            }
                        }
                    }
                }
            }

            if !viewModel.hiddenTags.isEmpty {
                Section(String(localized: "journal.tagManagement.hiddenTags")) {
                    ForEach(Array(viewModel.hiddenTags).sorted(), id: \.self) { tag in
                        HStack {
                            Text("#\(tag)")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .minimumScaleFactor(0.85)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                viewModel.restoreHiddenTag(tag)
                                // Rebuild allTags: include this tag if it's
                                // still referenced by any note.
                                if viewModel.tagUsageCount(tag) > 0,
                                   !viewModel.allTags.contains(tag) {
                                    viewModel.allTags.append(tag)
                                    viewModel.allTags.sort()
                                }
                            } label: {
                                Text(String(localized: "action.restore"))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Color.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "journal.manageTagsTitle"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            String(localized: "journal.tag.deleteTitle"),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible,
            presenting: pendingDeleteTag
        ) { tag in
            Button(
                String(localized: "journal.tag.deleteConfirm"),
                role: .destructive
            ) {
                viewModel.hideTagFromHistory(tag)
                pendingDeleteTag = nil
            }
            Button(String(localized: "action.cancel"), role: .cancel) {
                pendingDeleteTag = nil
            }
        } message: { tag in
            Text(String(localized: "journal.tag.deleteMessage \(tag)"))
        }
    }
}
