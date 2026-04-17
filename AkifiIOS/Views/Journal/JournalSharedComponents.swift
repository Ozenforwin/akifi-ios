import SwiftUI

// MARK: - Type Pill
//
// Compact inline capsule showing an entry's display type (Note / Reflection).
// Replaces the 4pt accent bar used in v1. Per spec R2.1.
struct JournalTypePill: View {
    let displayType: JournalDisplayType

    private var tint: Color {
        displayType == .reflection ? Color.budget : Color.accent
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: displayType.icon)
                .font(.caption2)
            Text(displayType.localizedName)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.10)))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(displayType.localizedName))
    }
}

// MARK: - Suggestion Chip
//
// Tag suggestion chip with context-menu affordance for deleting tags from
// history (spec R2.4, R2.5). `onTap` adds the tag to the form; `onDelete`
// triggers the confirmation dialog upstream.
struct JournalSuggestionChip: View {
    let tag: String
    let onTap: () -> Void
    var onDelete: (() -> Void)? = nil

    var body: some View {
        Button(action: onTap) {
            Text("#\(tag)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color(.quaternarySystemFill)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "journal.tag.add \(tag)")))
        .contextMenu {
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Label(
                        String(localized: "journal.tag.deleteFromHistory"),
                        systemImage: "trash"
                    )
                }
            }
        }
    }
}

// MARK: - Create Tag Chip
//
// Inline pseudo-chip that appears when the user types a query with no
// matching suggestions — tapping commits the new tag.
struct CreateTagChip: View {
    let tag: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.caption2)
                Text("#\(tag)")
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(Color.accent)
            .background(Capsule().stroke(Color.accent, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tag Filter Sheet
//
// Shown when the user taps "+N" in the filter bar (spec R2.3). Full list of
// tags sorted by frequency, each tappable to toggle as an active filter.
// Swipe-to-delete removes the tag from suggestion history (viewModel side).
struct TagFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: JournalViewModel
    @State private var pendingDeleteTag: String?
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.tagsByFrequency, id: \.self) { tag in
                    HStack {
                        Text("#\(tag)")
                            .font(.body)
                            .minimumScaleFactor(0.85)
                        Spacer()
                        if viewModel.selectedTag == tag {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accent)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if viewModel.selectedTag == tag {
                            viewModel.selectedTag = nil
                        } else {
                            viewModel.selectedTag = tag
                        }
                        viewModel.refilter()
                        dismiss()
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeleteTag = tag
                            showDeleteConfirm = true
                        } label: {
                            Label(
                                String(localized: "action.delete"),
                                systemImage: "trash"
                            )
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "journal.tags"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "action.done")) { dismiss() }
                }
            }
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
        .presentationDetents([.medium, .large])
    }
}
