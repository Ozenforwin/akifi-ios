import SwiftUI
import PhotosUI

/// Unified entry form for both Notes and Reflections (Journal v2).
/// - Type toggle at the top (Note / Reflection).
/// - Note: title + body text area.
/// - Reflection: structured period card + 4 guided prompts.
/// - Emoji-only mood row (accessibility labels for names).
/// - Collapsed "More details" section containing Tags / Photos / Transaction / Period.
struct JournalNoteFormView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    let viewModel: JournalViewModel
    var editingNote: FinancialNote?
    var preselectedTransactionId: String?
    var initialType: JournalDisplayType = .note
    /// Open the transaction picker immediately on appear (quick-action "About a purchase").
    var openTransactionPickerOnAppear: Bool = false

    // MARK: - State
    @State private var title = ""
    @State private var content = ""
    /// Per-prompt answers for the Reflection structured form. Index matches
    /// `reflectionPrompts`.
    @State private var promptAnswers: [String] = Array(repeating: "", count: 4)
    @State private var selectedMood: NoteMood?
    @State private var tags: [String] = []
    @State private var tagInput = ""
    @State private var displayType: JournalDisplayType = .note
    @State private var selectedTransactionId: String?
    @State private var isSaving = false
    @State private var errorText: String?
    @State private var showDetails = false
    @State private var showTransactionPicker = false

    // Photos
    @State private var newPhotoItems: [PhotosPickerItem] = []
    @State private var pendingPhotos: [PendingPhoto] = []
    @State private var existingPhotoUrls: [String] = []
    @State private var deletedPhotoUrls: [String] = []

    // Period (Reflection only)
    @State private var periodStart = Date()
    @State private var periodEnd = Date()
    @State private var hasPeriod = false

    // Tag history deletion (spec R2.5 Surface 1)
    @State private var pendingDeleteTag: String?
    @State private var showDeleteTagConfirm = false

    @FocusState private var contentFocused: Bool
    @FocusState private var tagFieldFocused: Bool

    private var isEditing: Bool { editingNote != nil }
    private var totalPhotoCount: Int { pendingPhotos.count + existingPhotoUrls.count }
    private var isReflection: Bool { displayType == .reflection }

    /// The canonical list of reflection prompts. Order matters — the parser
    /// reads sections in order when editing.
    private static let reflectionPromptKeys: [String] = [
        "journal.reflection.formPrompt.win",
        "journal.reflection.formPrompt.change",
        "journal.reflection.formPrompt.insight",
        "journal.reflection.formPrompt.nextGoal"
    ]

    private var reflectionPrompts: [String] {
        Self.reflectionPromptKeys.map { String(localized: String.LocalizationValue($0)) }
    }

    /// True when at least one prompt answer has real content — used to gate
    /// the Save button for reflections.
    private var hasAnyReflectionAnswer: Bool {
        promptAnswers.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Main save-button guard that switches between Note (content required)
    /// and Reflection (≥1 prompt answered) rules.
    private var isSaveDisabled: Bool {
        if isSaving { return true }
        if isReflection { return !hasAnyReflectionAnswer }
        return content.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    typeToggle
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 12)

                    if isReflection {
                        reflectionContentArea
                    } else {
                        contentArea
                    }

                    moodRow
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                    Divider().padding(.horizontal, 16)

                    detailsHeader
                    if showDetails {
                        detailsBody
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Color.clear.frame(height: 40)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "action.save")) {
                        Task { await save() }
                    }
                    .disabled(isSaveDisabled)
                    .fontWeight(.semibold)
                }
            }
            .alert(
                String(localized: "error.prefix"),
                isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })
            ) {
                Button("OK") {}
            } message: {
                Text(errorText ?? "")
            }
            .sheet(isPresented: $showTransactionPicker) {
                TransactionPickerSheet(selectedId: selectedTransactionId) { tx in
                    selectedTransactionId = tx.id
                }
            }
            .confirmationDialog(
                String(localized: "journal.tag.deleteTitle"),
                isPresented: $showDeleteTagConfirm,
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
            .task(id: newPhotoItems.count) {
                await ingestNewPhotoItems()
            }
            .onAppear {
                populateFromEditingIfNeeded()
                if openTransactionPickerOnAppear && !isEditing {
                    showTransactionPicker = true
                }
            }
        }
    }

    private var navTitle: String {
        if isEditing {
            return String(localized: "journal.editNote")
        }
        return isReflection
            ? String(localized: "journal.newReflection")
            : String(localized: "journal.newNote")
    }

    // MARK: - Type Toggle

    private var typeToggle: some View {
        HStack(spacing: 4) {
            TypeToggleButton(
                title: JournalDisplayType.note.localizedName,
                icon: JournalDisplayType.note.icon,
                isSelected: displayType == .note
            ) {
                withAnimation(.easeInOut(duration: 0.15)) { displayType = .note }
            }
            TypeToggleButton(
                title: JournalDisplayType.reflection.localizedName,
                icon: JournalDisplayType.reflection.icon,
                isSelected: displayType == .reflection
            ) {
                withAnimation(.easeInOut(duration: 0.15)) { displayType = .reflection }
                if !hasPeriod {
                    // Default to current month
                    let cal = Calendar.current
                    if let start = cal.dateInterval(of: .month, for: Date())?.start {
                        periodStart = start
                        periodEnd = cal.date(byAdding: DateComponents(month: 1, day: -1), to: start) ?? Date()
                        hasPeriod = true
                    }
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        )
    }

    // MARK: - Content Area (Note)

    private var contentArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(
                String(localized: "journal.titlePlaceholder"),
                text: $title
            )
            .font(.title3.weight(.semibold))
            .padding(EdgeInsets(top: 4, leading: 16, bottom: 0, trailing: 16))
            .submitLabel(.next)

            ZStack(alignment: .topLeading) {
                if content.isEmpty {
                    Text(String(localized: "journal.contentPlaceholder"))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 12)
                        .padding(.leading, 20)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $content)
                    .font(.body)
                    .frame(minHeight: 160)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .focused($contentFocused)
            }
        }
    }

    // MARK: - Content Area (Reflection)
    //
    // Structured experience (spec P1.9): Period card with live summary,
    // optional title, then one TextEditor per guided prompt.

    private var reflectionContentArea: some View {
        VStack(alignment: .leading, spacing: 16) {
            reflectionPeriodCard

            TextField(
                String(localized: "journal.reflection.titlePlaceholder"),
                text: $title
            )
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(reflectionPrompts.enumerated()), id: \.offset) { idx, prompt in
                    ReflectionPromptBlock(
                        prompt: prompt,
                        text: Binding(
                            get: { promptAnswers.indices.contains(idx) ? promptAnswers[idx] : "" },
                            set: { newValue in
                                while promptAnswers.count <= idx {
                                    promptAnswers.append("")
                                }
                                promptAnswers[idx] = newValue
                            }
                        )
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .padding(.top, 4)
    }

    private var reflectionPeriodCard: some View {
        let summary = ReflectionPeriodMath.compute(
            periodStart: periodStartStr,
            periodEnd: periodEndStr,
            transactions: appViewModel.dataStore.transactions,
            categories: appViewModel.dataStore.categories,
            currencyManager: appViewModel.currencyManager,
            accountsById: Dictionary(appViewModel.dataStore.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        )

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.footnote)
                    .foregroundStyle(Color.budget)
                Text(summary.periodLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.budget)
                Spacer()
                Menu {
                    Button(String(localized: "journal.reflection.period.thisMonth")) {
                        applyQuickPeriod(.thisMonth)
                    }
                    Button(String(localized: "journal.reflection.period.lastMonth")) {
                        applyQuickPeriod(.lastMonth)
                    }
                    Button(String(localized: "journal.reflection.period.thisWeek")) {
                        applyQuickPeriod(.thisWeek)
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(String(localized: "journal.reflection.period.change"))
                            .font(.caption.weight(.medium))
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(Color.budget)
                }
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
                .fill(Color.budget.opacity(0.06))
        )
        .padding(.horizontal, 16)
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

    private enum QuickPeriod { case thisMonth, lastMonth, thisWeek }

    private func applyQuickPeriod(_ p: QuickPeriod) {
        let cal = Calendar.current
        switch p {
        case .thisMonth:
            if let interval = cal.dateInterval(of: .month, for: Date()) {
                periodStart = interval.start
                periodEnd = cal.date(byAdding: DateComponents(day: -1), to: interval.end) ?? interval.end
            }
        case .lastMonth:
            if let lastMonth = cal.date(byAdding: .month, value: -1, to: Date()),
               let interval = cal.dateInterval(of: .month, for: lastMonth) {
                periodStart = interval.start
                periodEnd = cal.date(byAdding: DateComponents(day: -1), to: interval.end) ?? interval.end
            }
        case .thisWeek:
            if let interval = cal.dateInterval(of: .weekOfYear, for: Date()) {
                periodStart = interval.start
                periodEnd = cal.date(byAdding: DateComponents(day: -1), to: interval.end) ?? interval.end
            }
        }
        hasPeriod = true
    }

    private var periodStartStr: String? {
        guard isReflection else { return nil }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        return df.string(from: periodStart)
    }

    private var periodEndStr: String? {
        guard isReflection else { return nil }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        return df.string(from: periodEnd)
    }

    // MARK: - Mood Row

    private var moodRow: some View {
        HStack(spacing: 0) {
            Text(String(localized: "journal.mood"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 4) {
                ForEach(NoteMood.allCases, id: \.self) { mood in
                    MoodButton(mood: mood, isSelected: selectedMood == mood) {
                        if selectedMood == mood {
                            selectedMood = nil
                        } else {
                            selectedMood = mood
                        }
                    }
                }
            }
        }
    }

    // MARK: - Details section

    private var detailsHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { showDetails.toggle() }
        } label: {
            HStack {
                Label(String(localized: "journal.moreDetails"), systemImage: "chevron.right.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    private var detailsBody: some View {
        VStack(alignment: .leading, spacing: 20) {
            tagsBlock
            photosBlock
            if !isReflection {
                transactionLinkerBlock
            }
            if isReflection {
                periodBlock
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Tags (spec R2.4)

    private var tagSuggestions: [String] {
        let q = tagInput.trimmingCharacters(in: .whitespaces).lowercased()
        let base = viewModel.tagsByFrequency.isEmpty ? viewModel.allTags : viewModel.tagsByFrequency
        let available = base.filter { !tags.contains($0) }
        if q.isEmpty {
            return Array(available.prefix(8))
        }
        return Array(available.filter { $0.hasPrefix(q) }.prefix(8))
    }

    private var tagsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Section 1: Applied tags ────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "journal.tags"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)

                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        RemovableTagChip(tag: tag) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                tags.removeAll { $0 == tag }
                            }
                        }
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                    inlineAddTagField
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                // Force the custom Layout to report correct intrinsic height
                // to the parent VStack — without this the suggestions row
                // overlapped multi-row applied chips (BUG-006).
                .fixedSize(horizontal: false, vertical: true)
            }

            let q = tagInput.trimmingCharacters(in: .whitespaces).lowercased()
            let showSuggestions = !tagSuggestions.isEmpty || (!q.isEmpty && tagSuggestions.isEmpty)

            if showSuggestions {
                Divider()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        q.isEmpty
                            ? String(localized: "journal.tags.suggested")
                            : String(localized: "journal.tags.matching")
                    )
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            if !q.isEmpty, tagSuggestions.isEmpty {
                                CreateTagChip(tag: q) { commitTagInput() }
                            } else {
                                ForEach(tagSuggestions, id: \.self) { tag in
                                    JournalSuggestionChip(
                                        tag: tag,
                                        onTap: { addTag(tag) },
                                        onDelete: {
                                            pendingDeleteTag = tag
                                            showDeleteTagConfirm = true
                                        }
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                    }
                }
            }
        }
    }

    private var inlineAddTagField: some View {
        HStack(spacing: 4) {
            Image(systemName: "plus")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField(String(localized: "journal.tagPlaceholder"), text: $tagInput)
                .font(.caption.weight(.medium))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .frame(minWidth: 60, maxWidth: 120)
                .focused($tagFieldFocused)
                .onSubmit { commitTagInput() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().stroke(
                tagInput.isEmpty ? Color(.systemGray4) : Color.accent,
                lineWidth: tagInput.isEmpty ? 1 : 1.5
            )
        )
    }

    private func commitTagInput() {
        let tag = tagInput.trimmingCharacters(in: .whitespaces).lowercased()
        tagInput = ""
        guard !tag.isEmpty, !tags.contains(tag) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            tags.append(tag)
        }
        tagFieldFocused = true
    }

    private func addTag(_ tag: String) {
        guard !tags.contains(tag) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            tags.append(tag)
        }
    }

    // MARK: - Photos

    private var photosBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "journal.photos"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(localized: "journal.photos.count \(totalPhotoCount) \(5)"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(existingPhotoUrls, id: \.self) { urlString in
                        existingPhotoCell(urlString: urlString)
                    }
                    ForEach(pendingPhotos) { photo in
                        pendingPhotoCell(photo)
                    }
                    if totalPhotoCount < 5 {
                        addPhotoCell
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func existingPhotoCell(urlString: String) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let url = URL(string: urlString) {
                    CachedAsyncImage(url: url) {
                        Color(.systemGray5)
                    }
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            Button {
                withAnimation {
                    existingPhotoUrls.removeAll { $0 == urlString }
                    deletedPhotoUrls.append(urlString)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.white)
                    .background(Circle().fill(Color.black.opacity(0.4)))
                    .shadow(radius: 2)
            }
            .offset(x: 6, y: -6)
            .accessibilityLabel(Text(String(localized: "journal.photo.remove")))
        }
    }

    private func pendingPhotoCell(_ photo: PendingPhoto) -> some View {
        ZStack(alignment: .topTrailing) {
            if let image = photo.thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(.systemGray5))
                    .frame(width: 80, height: 80)
                    .overlay(ProgressView())
            }
            if photo.isUploading {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.3))
                    .frame(width: 80, height: 80)
                    .overlay {
                        VStack(spacing: 4) {
                            ProgressView(value: photo.progress)
                                .progressViewStyle(.linear)
                                .tint(.white)
                                .frame(width: 60)
                            Text("\(Int(photo.progress * 100))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white)
                        }
                    }
            }
            Button {
                withAnimation {
                    pendingPhotos.removeAll { $0.id == photo.id }
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.white)
                    .background(Circle().fill(Color.black.opacity(0.4)))
                    .shadow(radius: 2)
            }
            .offset(x: 6, y: -6)
        }
    }

    private var addPhotoCell: some View {
        PhotosPicker(
            selection: $newPhotoItems,
            maxSelectionCount: max(0, 5 - totalPhotoCount),
            matching: .images
        ) {
            VStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.title3)
                    .foregroundStyle(Color.accent)
                Text(String(localized: "action.add"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 80, height: 80)
            .background(Color(.quaternarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(.systemGray4), style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
        }
    }

    // MARK: - Transaction linker

    @ViewBuilder
    private var transactionLinkerBlock: some View {
        if let txId = selectedTransactionId,
           let tx = appViewModel.dataStore.transactions.first(where: { $0.id == txId }) {
            linkedTransactionFilledRow(tx)
                .padding(.horizontal, 16)
        } else {
            linkedTransactionEmptyRow
                .padding(.horizontal, 16)
        }
    }

    private var linkedTransactionEmptyRow: some View {
        Button {
            showTransactionPicker = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.accent.opacity(0.10))
                        .frame(width: 36, height: 36)
                    Image(systemName: "link")
                        .foregroundStyle(Color.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "journal.linker.emptyTitle"))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Text(String(localized: "journal.linker.emptySubtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "journal.linker.emptyTitle")))
        .accessibilityHint(Text(String(localized: "journal.linker.emptyHint")))
    }

    private func linkedTransactionFilledRow(_ tx: Transaction) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill((tx.type == .income ? Color.income : Color.expense).opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: tx.type == .income ? "arrow.down" : "arrow.up")
                    .foregroundStyle(tx.type == .income ? Color.income : Color.expense)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(appViewModel.currencyManager.formatAmount(appViewModel.dataStore.amountInBaseDisplay(tx)))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                let subtitle = [
                    appViewModel.dataStore.category(for: tx)?.name,
                    tx.date
                ].compactMap { $0 }.joined(separator: " · ")
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                selectedTransactionId = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(Text(String(localized: "journal.linker.clear")))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((tx.type == .income ? Color.income : Color.expense).opacity(0.06))
        )
        .contentShape(Rectangle())
        .onTapGesture { showTransactionPicker = true }
    }

    // MARK: - Period (Reflection)

    private var periodBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "journal.period"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            DatePicker(
                String(localized: "journal.period.start"),
                selection: $periodStart,
                displayedComponents: .date
            )
            DatePicker(
                String(localized: "journal.period.end"),
                selection: $periodEnd,
                in: periodStart...,
                displayedComponents: .date
            )
        }
        .padding(.horizontal, 16)
        .onChange(of: periodStart) { _, _ in hasPeriod = true }
        .onChange(of: periodEnd) { _, _ in hasPeriod = true }
    }

    // MARK: - Actions

    private func ingestNewPhotoItems() async {
        guard !newPhotoItems.isEmpty else { return }
        let items = newPhotoItems
        newPhotoItems = []
        for item in items {
            var thumb: UIImage?
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                thumb = downsample(image, maxEdge: 160)
            }
            pendingPhotos.append(PendingPhoto(item: item, thumbnail: thumb))
        }
    }

    private func populateFromEditingIfNeeded() {
        if let note = editingNote {
            title = note.title ?? ""
            content = note.content
            selectedMood = note.mood
            tags = note.tags ?? []
            displayType = note.noteType.displayType
            selectedTransactionId = note.transactionId
            existingPhotoUrls = note.photoUrls ?? []
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            if let startStr = note.periodStart, let startDate = df.date(from: startStr) {
                periodStart = startDate
                hasPeriod = true
            }
            if let endStr = note.periodEnd, let endDate = df.date(from: endStr) {
                periodEnd = endDate
                hasPeriod = true
            }
            // Split structured reflection answers back into the prompts grid.
            if displayType == .reflection,
               let sections = ReflectionSectionParser.parse(note.content) {
                promptAnswers = Array(repeating: "", count: reflectionPrompts.count)
                for (idx, prompt) in reflectionPrompts.enumerated() {
                    if let match = sections.first(where: { $0.prompt == prompt }) {
                        promptAnswers[idx] = match.answer
                    }
                }
            }
            showDetails = !tags.isEmpty
                || !existingPhotoUrls.isEmpty
                || selectedTransactionId != nil
                || note.periodStart != nil
        } else {
            displayType = initialType
            if let tx = preselectedTransactionId {
                selectedTransactionId = tx
                showDetails = true
            }
            if initialType == .reflection && !hasPeriod {
                let cal = Calendar.current
                if let start = cal.dateInterval(of: .month, for: Date())?.start {
                    periodStart = start
                    periodEnd = cal.date(byAdding: DateComponents(month: 1, day: -1), to: start) ?? Date()
                    hasPeriod = true
                }
            }
        }
    }

    /// Build the final `content` string. For reflections, join prompt answers
    /// using the `### <prompt>\n<answer>` section format so the parser can
    /// round-trip them back into the form when editing.
    private func composedContent() -> String {
        if isReflection {
            var parts: [String] = []
            for (idx, prompt) in reflectionPrompts.enumerated() {
                let answer = promptAnswers.indices.contains(idx)
                    ? promptAnswers[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
                guard !answer.isEmpty else { continue }
                parts.append("### \(prompt)\n\(answer)")
            }
            return parts.joined(separator: "\n\n")
        }
        return content
    }

    private func save() async {
        isSaving = true
        errorText = nil
        defer { isSaving = false }

        do {
            let userId = try await SupabaseManager.shared.currentUserId()
            let noteId = editingNote?.id ?? UUID().uuidString.lowercased()
            let finalContent = composedContent()

            // 1. Upload pending photos first.
            var uploadedUrls: [String] = []
            for idx in pendingPhotos.indices {
                pendingPhotos[idx].isUploading = true
                let photoId = pendingPhotos[idx].id
                do {
                    let url = try await JournalPhotoUploader.upload(
                        item: pendingPhotos[idx].item,
                        userId: userId,
                        noteId: noteId
                    ) { progress in
                        Task { @MainActor [photoId] in
                            if let i = self.pendingPhotos.firstIndex(where: { $0.id == photoId }) {
                                self.pendingPhotos[i].progress = progress
                            }
                        }
                    }
                    uploadedUrls.append(url)
                    pendingPhotos[idx].isUploading = false
                    pendingPhotos[idx].progress = 1
                } catch {
                    pendingPhotos[idx].isUploading = false
                    errorText = error.localizedDescription
                    return
                }
            }

            let finalPhotoUrls = existingPhotoUrls + uploadedUrls
            let finalTitle = title.trimmingCharacters(in: .whitespaces).isEmpty ? nil : title
            let finalTags: [String]? = tags.isEmpty ? nil : tags

            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            let periodStartStr = isReflection ? df.string(from: periodStart) : nil
            let periodEndStr = isReflection ? df.string(from: periodEnd) : nil

            if let editing = editingNote {
                // When editing, always send title (empty string = clear) and tags.
                try await viewModel.updateNote(
                    id: editing.id,
                    title: finalTitle ?? "",
                    content: finalContent,
                    transactionId: .some(isReflection ? nil : selectedTransactionId),
                    tags: finalTags ?? [],
                    mood: selectedMood,
                    photoUrls: finalPhotoUrls,
                    periodStart: .some(periodStartStr),
                    periodEnd: .some(periodEndStr)
                )
                // Clean up remotely-deleted photos.
                for url in deletedPhotoUrls {
                    await JournalPhotoUploader.delete(publicURL: url)
                }
                AnalyticsService.logEvent("journal_note_updated", params: ["type": editing.noteType.rawValue])
            } else {
                let storageType: NoteType = displayType.storageType
                _ = try await viewModel.createNote(
                    title: finalTitle,
                    content: finalContent,
                    transactionId: isReflection ? nil : (selectedTransactionId ?? preselectedTransactionId),
                    tags: finalTags,
                    mood: selectedMood,
                    photoUrls: finalPhotoUrls.isEmpty ? nil : finalPhotoUrls,
                    noteType: storageType,
                    periodStart: periodStartStr,
                    periodEnd: periodEndStr,
                    noteId: noteId
                )
            }
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func downsample(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxEdge else { return image }
        let ratio = maxEdge / longest
        let newSize = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

// MARK: - Reflection Prompt Block

struct ReflectionPromptBlock: View {
    let prompt: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(prompt)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(String(localized: "journal.reflection.promptPlaceholder"))
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 4)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(focused ? Color.budget.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
    }
}

// MARK: - Supporting types

/// A photo selected in the form but not yet uploaded.
struct PendingPhoto: Identifiable {
    let id = UUID()
    let item: PhotosPickerItem
    var thumbnail: UIImage?
    var isUploading: Bool = false
    var progress: Double = 0
}

struct TypeToggleButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.footnote)
                Text(title)
                    .font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color(.systemBackground) : Color.clear)
                    .shadow(color: isSelected ? Color.black.opacity(0.08) : .clear, radius: 2, x: 0, y: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct MoodButton: View {
    let mood: NoteMood
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(mood.emoji)
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(
                    Circle().fill(isSelected ? Color.accent.opacity(0.15) : Color(.quaternarySystemFill))
                )
                .overlay(
                    Circle().stroke(isSelected ? Color.accent : Color.clear, lineWidth: 1.5)
                )
                .scaleEffect(isSelected ? 1.08 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(mood.localizedName))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct RemovableTagChip: View {
    let tag: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("#\(tag)")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.budget)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.budget.opacity(0.6))
            }
            .accessibilityLabel(Text(String(localized: "journal.tag.remove \(tag)")))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.budget.opacity(0.10)))
    }
}

// Safe subscript helper for arrays.
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
