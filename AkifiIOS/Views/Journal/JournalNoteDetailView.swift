import SwiftUI

struct JournalNoteDetailView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let note: FinancialNote
    let viewModel: JournalViewModel
    let dataStore: DataStore
    @State private var showEditSheet = false
    @State private var showDeleteAlert = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                content
                if let transactionId = note.transactionId { transactionLink(transactionId) }
                if let tags = note.tags, !tags.isEmpty { tagsView(tags) }
                if let photos = note.photoUrls, !photos.isEmpty { photosGrid(photos) }
            }
            .padding(16)
        }
        .navigationTitle(note.noteType.localizedName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showEditSheet = true
                    } label: {
                        Label(String(localized: "action.edit"), systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        showDeleteAlert = true
                    } label: {
                        Label(String(localized: "action.delete"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            JournalNoteFormView(viewModel: viewModel, editingNote: note)
                .presentationBackground(.ultraThinMaterial)
        }
        .alert(String(localized: "journal.deleteConfirm"), isPresented: $showDeleteAlert) {
            Button(String(localized: "action.delete"), role: .destructive) {
                Task {
                    await viewModel.deleteNote(note)
                    dismiss()
                }
            }
            Button(String(localized: "action.cancel"), role: .cancel) {}
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: note.noteType.icon)
                    .font(.title3)
                    .foregroundStyle(iconColor)

                if let mood = note.mood {
                    Text(mood.emoji)
                        .font(.title2)
                }

                Spacer()

                Text(formatDate(note.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let title = note.title, !title.isEmpty {
                Text(title)
                    .font(.title2.weight(.bold))
            }
        }
    }

    private var content: some View {
        Text(note.content)
            .font(.body)
            .textSelection(.enabled)
    }

    private func transactionLink(_ transactionId: String) -> some View {
        Group {
            if let tx = dataStore.transactions.first(where: { $0.id == transactionId }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "journal.linkedTransaction"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Image(systemName: tx.type == .income ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                            .foregroundStyle(tx.type == .income ? Color.income : Color.expense)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appViewModel.currencyManager.formatAmount(tx.amount.displayAmount))
                                .font(.subheadline.weight(.semibold))
                            if let cat = dataStore.category(for: tx) {
                                Text(cat.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(tx.date)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private func tagsView(_ tags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "journal.tags"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Text("#\(tag)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.purple.opacity(0.1)))
                }
            }
        }
    }

    private func photosGrid(_ urls: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "journal.photos"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                ForEach(urls, id: \.self) { urlString in
                    if let url = URL(string: urlString) {
                        CachedAsyncImage(url: url) {
                            Color(.systemGray5)
                        }
                        .frame(height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
    }

    private var iconColor: Color {
        switch note.noteType {
        case .transaction: .blue
        case .reflection: .purple
        case .freeform: .orange
        }
    }

    private func formatDate(_ raw: String?) -> String {
        guard let raw else { return "" }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let date = df.date(from: String(raw.prefix(19))) else { return String(raw.prefix(10)) }
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .short
        return display.string(from: date)
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (positions, CGSize(width: maxWidth, height: y + rowHeight))
    }
}
