import SwiftUI

struct JournalNoteCardView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let note: FinancialNote
    let dataStore: DataStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: note.noteType.icon)
                    .font(.caption)
                    .foregroundStyle(iconColor)

                if let mood = note.mood {
                    Text(mood.emoji)
                        .font(.caption)
                }

                if let title = note.title, !title.isEmpty {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                } else {
                    Text(note.content)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }

                Spacer()

                Text(formatTime(note.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if note.title != nil {
                Text(note.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let transactionId = note.transactionId,
               let tx = dataStore.transactions.first(where: { $0.id == transactionId }) {
                linkedTransactionBadge(tx)
            }

            if let tags = note.tags, !tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(tags.prefix(3), id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.purple.opacity(0.1)))
                    }
                    if tags.count > 3 {
                        Text("+\(tags.count - 3)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let photos = note.photoUrls, !photos.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "photo")
                        .font(.caption2)
                    Text("\(photos.count)")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
    }

    private var iconColor: Color {
        switch note.noteType {
        case .transaction: .blue
        case .reflection: .purple
        case .freeform: .orange
        }
    }

    private func linkedTransactionBadge(_ tx: Transaction) -> some View {
        HStack(spacing: 4) {
            Image(systemName: tx.type == .income ? "arrow.down" : "arrow.up")
                .font(.caption2)
            Text(appViewModel.currencyManager.formatAmount(tx.amount.displayAmount))
                .font(.caption.weight(.medium))
            if let cat = dataStore.category(for: tx) {
                Text("· \(cat.name)")
                    .font(.caption2)
            }
        }
        .foregroundStyle(tx.type == .income ? Color.income : Color.expense)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill((tx.type == .income ? Color.income : Color.expense).opacity(0.1))
        )
    }

    private func formatTime(_ raw: String?) -> String {
        guard let raw, raw.count >= 16 else { return "" }
        return String(raw.dropFirst(11).prefix(5))
    }
}
