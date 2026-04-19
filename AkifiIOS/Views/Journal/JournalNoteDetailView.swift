import SwiftUI

struct JournalNoteDetailView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let note: FinancialNote
    let viewModel: JournalViewModel
    let dataStore: DataStore
    @State private var showEditSheet = false
    @State private var showDeleteAlert = false
    @State private var photoViewerIndex: Int?
    @Environment(\.dismiss) private var dismiss

    private var displayType: JournalDisplayType { note.noteType.displayType }
    private var linkedTransaction: Transaction? {
        guard let id = note.transactionId else { return nil }
        return dataStore.transactions.first(where: { $0.id == id })
    }
    private var isReflection: Bool { displayType == .reflection }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                detailHeader

                // Reflection: show structured period summary + parsed prompts.
                // Note: show plain body text.
                if isReflection {
                    if note.periodStart != nil {
                        ReflectionPeriodCard(
                            note: note,
                            dataStore: dataStore,
                            currencyManager: appViewModel.currencyManager
                        )
                        .padding(.horizontal, 16)
                    }
                    reflectionBody
                } else {
                    contentView
                }

                if let tx = linkedTransaction {
                    linkedTransactionCard(tx).padding(.horizontal, 16)
                }

                if let photos = note.photoUrls, !photos.isEmpty {
                    photoGrid(photos).padding(.horizontal, 16)
                }

                if let tags = note.tags, !tags.isEmpty {
                    tagsFlow(tags).padding(.horizontal, 16)
                }

                Spacer(minLength: 40)
            }
            .padding(.top, 8)
        }
        .navigationTitle("")
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
        .sheet(item: Binding(
            get: { photoViewerIndex.map { PhotoViewerRoute(index: $0) } },
            set: { photoViewerIndex = $0?.index }
        )) { route in
            JournalPhotoViewer(urls: note.photoUrls ?? [], initialIndex: route.index)
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

    // MARK: - Header (spec R2.6)

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                JournalTypePill(displayType: displayType)
                Spacer()
                Text(formatDate(note.createdAt))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let title = note.title, !title.isEmpty {
                Text(title)
                    .font(.title2.weight(.bold))
            }
            if let mood = note.mood {
                HStack(alignment: .center, spacing: 6) {
                    Text(mood.emoji)
                        .font(.body)
                    Text(mood.localizedName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Content (standard note)

    private var contentView: some View {
        Text(note.content)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
    }

    // MARK: - Reflection body (structured prompts)

    @ViewBuilder
    private var reflectionBody: some View {
        if let sections = ReflectionSectionParser.parse(note.content) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.prompt)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(section.answer)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
        } else {
            contentView
        }
    }

    // MARK: - Linked tx

    private func linkedTransactionCard(_ tx: Transaction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(String(localized: "journal.linkedTransaction"), systemImage: "link")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill((tx.type == .income ? Color.income : Color.expense).opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: tx.type == .income ? "arrow.down" : "arrow.up")
                        .foregroundStyle(tx.type == .income ? Color.income : Color.expense)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(appViewModel.currencyManager.formatAmount(tx.amount.displayAmount))
                        .font(.headline.monospacedDigit())
                    if let cat = dataStore.category(for: tx) {
                        Text(cat.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(tx.date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - Photos

    @ViewBuilder
    private func photoGrid(_ urls: [String]) -> some View {
        if urls.count == 1 {
            singlePhotoView(urls[0], index: 0)
        } else if urls.count == 2 {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(Array(urls.enumerated()), id: \.offset) { idx, url in
                    photoThumbTappable(url, index: idx, height: 160, radius: 12)
                }
            }
        } else {
            VStack(spacing: 8) {
                singlePhotoView(urls[0], index: 0, height: 200)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(Array(urls.enumerated()).dropFirst(), id: \.offset) { idx, url in
                        photoThumbTappable(url, index: idx, height: 100, radius: 8)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func singlePhotoView(_ urlString: String, index: Int, height: CGFloat = 240) -> some View {
        if let url = URL(string: urlString) {
            CachedAsyncImage(url: url) {
                Color(.systemGray5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { photoViewerIndex = index }
        }
    }

    @ViewBuilder
    private func photoThumbTappable(_ urlString: String, index: Int, height: CGFloat, radius: CGFloat) -> some View {
        if let url = URL(string: urlString) {
            CachedAsyncImage(url: url) {
                Color(.systemGray5)
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { photoViewerIndex = index }
        }
    }

    // MARK: - Tags

    private func tagsFlow(_ tags: [String]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text("#\(tag)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.budget)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.budget.opacity(0.10)))
            }
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

/// Identifiable wrapper so we can use `.sheet(item:)` with an Int index.
private struct PhotoViewerRoute: Identifiable {
    let index: Int
    var id: Int { index }
}

// MARK: - Reflection Period Card (read-only)
//
// Shown at the top of a Reflection detail view. Mirrors the editable
// PeriodCard used in the form but without the date pickers.
struct ReflectionPeriodCard: View {
    let note: FinancialNote
    let dataStore: DataStore
    let currencyManager: CurrencyManager

    private var summary: ReflectionPeriodSummary {
        ReflectionPeriodMath.compute(
            note: note,
            transactions: dataStore.transactions,
            categories: dataStore.categories,
            currencyManager: currencyManager
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.footnote)
                    .foregroundStyle(Color.budget)
                Text(summary.periodLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.budget)
            }

            if summary.hasData {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        reflectionStat(
                            icon: "arrow.down.circle.fill",
                            iconColor: Color.income,
                            label: String(localized: "journal.reflection.income"),
                            value: summary.incomeFormatted
                        )
                        Divider().frame(height: 36)
                        reflectionStat(
                            icon: "arrow.up.circle.fill",
                            iconColor: Color.expense,
                            label: String(localized: "journal.reflection.expense"),
                            value: summary.expenseFormatted
                        )
                    }

                    HStack(spacing: 6) {
                        Image(systemName: summary.netIsPositive ? "plus.circle.fill" : "minus.circle.fill")
                            .font(.caption)
                            .foregroundStyle(summary.netIsPositive ? Color.income : Color.expense)
                        Text(String(localized: "journal.reflection.net"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(summary.netFormatted)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(summary.netIsPositive ? Color.income : Color.expense)
                        Spacer()
                        Text("\(summary.transactionCount) " + String(localized: "journal.reflection.txShort"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    if !summary.topCategoryNames.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "chart.pie.fill")
                                .font(.caption)
                                .foregroundStyle(Color.budget)
                            Text(String(localized: "journal.reflection.topCategoriesShort"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(summary.topCategoryNames.joined(separator: ", "))
                                .font(.caption.weight(.medium))
                                .lineLimit(2)
                        }
                    }
                }
            } else {
                Text(String(localized: "journal.reflection.noData"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    @ViewBuilder
    private func reflectionStat(icon: String, iconColor: Color, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(iconColor)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(iconColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

struct ReflectionPeriodSummary {
    let periodLabel: String
    let incomeFormatted: String
    let expenseFormatted: String
    let netFormatted: String
    let netIsPositive: Bool
    let totalFormatted: String
    let transactionCount: Int
    let topCategoryNames: [String]
    let hasData: Bool
}

/// Pure computation helper — used by both the detail card and the form's
/// period preview. Kept out of JournalViewModel to preserve testability.
/// `@MainActor` because it invokes `CurrencyManager.formatAmount`, which is
/// main-actor isolated.
@MainActor
enum ReflectionPeriodMath {
    static func compute(
        note: FinancialNote,
        transactions: [Transaction],
        categories: [Category],
        currencyManager: CurrencyManager
    ) -> ReflectionPeriodSummary {
        compute(
            periodStart: note.periodStart,
            periodEnd: note.periodEnd,
            transactions: transactions,
            categories: categories,
            currencyManager: currencyManager
        )
    }

    static func compute(
        periodStart: String?,
        periodEnd: String?,
        transactions: [Transaction],
        categories: [Category],
        currencyManager: CurrencyManager
    ) -> ReflectionPeriodSummary {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let display = DateFormatter()
        display.setLocalizedDateFormatFromTemplate("d MMM yyyy")

        let startDate = periodStart.flatMap { df.date(from: $0) }
        let endDate = periodEnd.flatMap { df.date(from: $0) }

        let label: String = {
            let startText = startDate.flatMap { display.string(from: $0) } ?? (periodStart ?? "")
            let endText = endDate.flatMap { display.string(from: $0) } ?? (periodEnd ?? "")
            if !endText.isEmpty { return "\(startText) – \(endText)" }
            return startText
        }()

        guard let start = startDate, let end = endDate else {
            let zero = currencyManager.formatAmount(0)
            return ReflectionPeriodSummary(
                periodLabel: label,
                incomeFormatted: zero,
                expenseFormatted: zero,
                netFormatted: zero,
                netIsPositive: true,
                totalFormatted: zero,
                transactionCount: 0,
                topCategoryNames: [],
                hasData: false
            )
        }

        let inPeriod = transactions.filter { tx in
            guard !tx.isTransfer, let d = df.date(from: tx.date) else { return false }
            return d >= start && d <= end
        }
        let expenses = inPeriod.filter { $0.type == .expense }
        let incomes = inPeriod.filter { $0.type == .income }

        let expenseTotal = expenses.reduce(Int64(0)) { $0 + abs($1.amount) }
        let incomeTotal = incomes.reduce(Int64(0)) { $0 + abs($1.amount) }
        let net = incomeTotal - expenseTotal

        var categoryTotals: [String: Int64] = [:]
        for tx in expenses {
            guard let cat = tx.categoryId else { continue }
            categoryTotals[cat, default: 0] += abs(tx.amountNative)
        }
        let topIds = categoryTotals
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map(\.key)
        let topNames = topIds.compactMap { id in
            categories.first(where: { $0.id == id })?.name
        }

        let netAbs = abs(net)
        let netPrefix = net >= 0 ? "+" : "−"

        return ReflectionPeriodSummary(
            periodLabel: label,
            incomeFormatted: currencyManager.formatAmount(incomeTotal.displayAmount),
            expenseFormatted: currencyManager.formatAmount(expenseTotal.displayAmount),
            netFormatted: netPrefix + currencyManager.formatAmount(netAbs.displayAmount),
            netIsPositive: net >= 0,
            totalFormatted: currencyManager.formatAmount(expenseTotal.displayAmount),
            transactionCount: inPeriod.count,
            topCategoryNames: topNames,
            hasData: !inPeriod.isEmpty
        )
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
