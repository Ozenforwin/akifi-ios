import SwiftUI

struct JournalNoteCardView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let note: FinancialNote
    let dataStore: DataStore

    private var displayType: JournalDisplayType { note.noteType.displayType }
    private var hasPhotos: Bool { (note.photoUrls ?? []).isEmpty == false }
    private var linkedTransaction: Transaction? {
        guard let id = note.transactionId else { return nil }
        return dataStore.transactions.first(where: { $0.id == id })
    }
    private var isReflection: Bool { displayType == .reflection }

    var body: some View {
        Group {
            if hasPhotos, let urls = note.photoUrls {
                photoFirstCard(urls: urls)
            } else if isReflection {
                reflectionCard
            } else {
                standardCard
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - Standard card (Variant A & C) — Note
    //
    // Per spec R2.7: no leading Rectangle, plain VStack, TypePill as type
    // differentiator, shadow matches TransactionRowView.

    private var standardCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow

            if let title = note.title, !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(note.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(note.content)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }

            if let tx = linkedTransaction {
                linkedTransactionBadge(tx)
            }

            if let tags = note.tags, !tags.isEmpty {
                tagChipRow(tags)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cardBackground)
        )
        .shadow(color: .primary.opacity(0.06), radius: 6, x: 0, y: 2)
    }

    // MARK: - Reflection card — structured summary preview (Journal v2 R2.1 + P1.9)

    private var reflectionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow

            if let period = formattedPeriodBadge() {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.caption2)
                    Text(period)
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(Color.budget)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.budget.opacity(0.10)))
            }

            // Title or first prompt excerpt.
            if let title = note.title, !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }

            // Reflection excerpt: prefer the first prompt answer, fall back
            // to the raw content.
            Text(reflectionExcerpt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            // Auto-computed summary for the period.
            if let summary = reflectionSummary {
                HStack(spacing: 10) {
                    summaryStat(
                        icon: "creditcard",
                        text: summary.totalText,
                        tint: Color.expense
                    )
                    summaryStat(
                        icon: "list.bullet",
                        text: summary.countText,
                        tint: Color.budget
                    )
                }
                .padding(.top, 2)
            }

            if let tags = note.tags, !tags.isEmpty {
                tagChipRow(tags)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cardBackground)
        )
        .shadow(color: .primary.opacity(0.06), radius: 6, x: 0, y: 2)
    }

    private func summaryStat(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(tint)
    }

    // MARK: - Photo-first card (Variant B)

    private func photoFirstCard(urls: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            photoThumbnailStrip(urls)

            VStack(alignment: .leading, spacing: 6) {
                headerRow

                if let title = note.title, !title.isEmpty {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                } else {
                    Text(note.content)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                }

                if let tx = linkedTransaction {
                    linkedTransactionBadge(tx)
                }

                if let tags = note.tags, !tags.isEmpty {
                    tagChipRow(tags)
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cardBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .primary.opacity(0.06), radius: 6, x: 0, y: 2)
    }

    private var cardBackground: Color {
        isReflection
            ? Color.budget.opacity(0.05)
            : Color(.secondarySystemGroupedBackground)
    }

    private func photoThumbnailStrip(_ urls: [String]) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 2) {
                if urls.count == 1 {
                    photoImage(urls[0], width: w, height: 140)
                } else if urls.count == 2 {
                    photoImage(urls[0], width: (w - 2) / 2, height: 140)
                    photoImage(urls[1], width: (w - 2) / 2, height: 140)
                } else {
                    photoImage(urls[0], width: w * 0.6, height: 140)
                    VStack(spacing: 2) {
                        photoImage(urls[1], width: w * 0.4 - 2, height: 69)
                        ZStack {
                            photoImage(urls[2], width: w * 0.4 - 2, height: 69)
                            if urls.count > 3 {
                                Color.black.opacity(0.45)
                                Text("+\(urls.count - 2)")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                }
            }
        }
        .frame(height: 140)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 12,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 12,
                style: .continuous
            )
        )
    }

    private func photoImage(_ urlString: String, width: CGFloat, height: CGFloat) -> some View {
        Group {
            if let url = URL(string: urlString) {
                CachedAsyncImage(url: url) {
                    Color(.systemGray5)
                }
                .frame(width: width, height: height)
                .clipped()
            } else {
                Color(.systemGray5)
                    .frame(width: width, height: height)
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 8) {
            JournalTypePill(displayType: displayType)
            if let mood = note.mood {
                Text(mood.emoji)
                    .font(.caption)
                    .accessibilityLabel(Text(mood.localizedName))
            }
            Spacer()
            Text(formatTime(note.createdAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func linkedTransactionBadge(_ tx: Transaction) -> some View {
        HStack(spacing: 6) {
            Image(systemName: tx.type == .income ? "arrow.down" : "arrow.up")
                .font(.caption2)
            Text(appViewModel.currencyManager.formatAmount(dataStore.amountInBaseDisplay(tx)))
                .font(.caption.weight(.semibold).monospacedDigit())
            if let cat = dataStore.category(for: tx) {
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(cat.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(tx.type == .income ? Color.income : Color.expense)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule().fill((tx.type == .income ? Color.income : Color.expense).opacity(0.08))
        )
    }

    private func tagChipRow(_ tags: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(tags.prefix(3), id: \.self) { tag in
                Text("#\(tag)")
                    .font(.caption2)
                    .foregroundStyle(Color.budget)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.budget.opacity(0.1)))
            }
            if tags.count > 3 {
                Text("+\(tags.count - 3)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatTime(_ raw: String?) -> String {
        guard let raw, raw.count >= 16 else { return "" }
        return String(raw.dropFirst(11).prefix(5))
    }

    // MARK: - Reflection helpers

    private var reflectionExcerpt: String {
        // Journal v2 P1.9: reflections stored with "### <prompt>\n<answer>"
        // sections. Surface only the first answer for list cards.
        let content = note.content
        if let parsed = ReflectionSectionParser.parse(content), let first = parsed.first {
            return first.answer
        }
        return content
    }

    private func formattedPeriodBadge() -> String? {
        guard let start = note.periodStart else { return nil }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let display = DateFormatter()
        display.setLocalizedDateFormatFromTemplate("d MMM yyyy")

        let startDate = df.date(from: start).flatMap { display.string(from: $0) } ?? start
        guard let end = note.periodEnd else { return startDate }
        let endDate = df.date(from: end).flatMap { display.string(from: $0) } ?? end
        return "\(startDate) – \(endDate)"
    }

    private struct ReflectionPeriodSummary {
        let totalText: String
        let countText: String
    }

    private var reflectionSummary: ReflectionPeriodSummary? {
        guard let start = note.periodStart, let end = note.periodEnd else { return nil }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        guard let startDate = df.date(from: start),
              let endDate = df.date(from: end) else { return nil }

        let transactions = dataStore.transactions.filter { tx in
            guard !tx.isTransfer, tx.type == .expense,
                  let txDate = df.date(from: tx.date) else { return false }
            return txDate >= startDate && txDate <= endDate
        }
        guard !transactions.isEmpty else { return nil }
        let total = transactions.reduce(Int64(0)) { $0 + abs(dataStore.amountInBase($1)) }
        let totalStr = appViewModel.currencyManager.formatAmount(total.displayAmount)
        return ReflectionPeriodSummary(
            totalText: totalStr,
            countText: String(
                format: String(localized: "journal.reflection.txCountShort %lld"),
                transactions.count
            )
        )
    }
}

// MARK: - Reflection content parser
//
// A reflection saved via the structured form stores prompts and answers as
// `### <prompt>\n<answer>` sections joined by blank lines. Legacy
// unstructured reflections (v1) are plain text and this parser returns nil.
enum ReflectionSectionParser {
    struct Section: Identifiable, Hashable {
        let id = UUID()
        let prompt: String
        let answer: String

        static func == (lhs: Section, rhs: Section) -> Bool {
            lhs.prompt == rhs.prompt && lhs.answer == rhs.answer
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(prompt); hasher.combine(answer)
        }
    }

    static func parse(_ content: String) -> [Section]? {
        // Each section begins with a line "### <prompt>".
        let marker = "### "
        guard content.contains(marker) else { return nil }
        var sections: [Section] = []
        var current: (prompt: String, answerLines: [String])?

        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix(marker) {
                if let c = current {
                    let answer = c.answerLines
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !answer.isEmpty {
                        sections.append(Section(prompt: c.prompt, answer: answer))
                    }
                }
                let prompt = String(line.dropFirst(marker.count))
                    .trimmingCharacters(in: .whitespaces)
                current = (prompt, [])
            } else if current != nil {
                current?.answerLines.append(line)
            }
        }
        if let c = current {
            let answer = c.answerLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !answer.isEmpty {
                sections.append(Section(prompt: c.prompt, answer: answer))
            }
        }
        return sections.isEmpty ? nil : sections
    }
}
