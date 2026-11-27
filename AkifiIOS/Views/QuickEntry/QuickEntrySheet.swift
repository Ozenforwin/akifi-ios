import SwiftUI
import UIKit

/// The quick-entry sheet (1.6.0): one field for amount and words with the
/// live parse under it, predicted category chips, account and date chips,
/// «Повторить», voice, and «Сохранить».
///
/// Common case: type «300», tap a category chip — with an amount in the
/// field a chip tap saves right away (undo in the toast). When the
/// prediction is confident the top chip is already selected and
/// «Сохранить» (or Return) is the only tap.
///
/// Liquid Glass (`.claude/design/liquid-glass.md`): a system sheet with
/// system toolbar items (glass on iOS 26); chips are content fills, not
/// glass (no glass on glass); the save button is `.akifiPrimary`.
struct QuickEntrySheet: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("hapticEnabled") private var hapticEnabled = true

    @Bindable var model: QuickEntrySheetModel
    var onClose: () -> Void
    var onSaved: (QuickEntrySaved) -> Void
    var onDetails: () -> Void

    @FocusState private var isFieldFocused: Bool
    @State private var showCategoryPicker = false
    @State private var showDatePicker = false
    @State private var largeExpense: TransactionGuards.LargeExpenseDecision?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    entrySection
                    if let status = model.voiceStatus {
                        voiceStatusRow(status)
                    }
                    categoryRow
                    accountAndDateRow
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.never)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .navigationTitle(String(localized: "transaction.newTransaction"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .presentationDetents([.medium, .large])
        .task { await start() }
        .onChange(of: model.speech.transcript) { _, transcript in
            model.applyTranscript(transcript)
        }
        .onChange(of: model.speech.state) { _, _ in
            model.speechStateDidChange()
            if model.voiceStatus?.fallsBackToTyping == true {
                isFieldFocused = true
            }
        }
        .onDisappear { model.cancelVoice() }
        .background { QuickEntryStoreObserver(model: model) }
        .sheet(isPresented: $showCategoryPicker) {
            CategoryPickerView(
                categories: model.categoriesForType,
                transactionType: model.draft.type,
                selectedCategoryId: Binding(
                    get: { model.draft.categoryId },
                    set: { id in
                        if let id { model.chooseCategory(id) } else { model.clearCategory() }
                    }
                )
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showDatePicker) { datePickerSheet }
        .alert(
            String(localized: "transaction.confirmLargeExpense.title"),
            isPresented: Binding(get: { largeExpense != nil }, set: { if !$0 { largeExpense = nil } }),
            presenting: largeExpense
        ) { _ in
            Button(String(localized: "transaction.confirmLargeExpense.confirm"), role: .destructive) {
                Task { await save(confirmed: true) }
            }
            Button(String(localized: "transaction.confirmLargeExpense.cancel"), role: .cancel) {}
        } message: { decision in
            Text(largeExpenseMessage(decision))
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                model.cancelVoice()
                onClose()
            } label: {
                Label(String(localized: "common.close"), systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
        }
        ToolbarItem(placement: .principal) {
            Picker(String(localized: "common.type"), selection: typeSelection) {
                Text(String(localized: "common.expense")).tag(TransactionType.expense)
                Text(String(localized: "common.income")).tag(TransactionType.income)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(String(localized: "quickEntry.sheet.more")) {
                onDetails()
            }
            .accessibilityHint(String(localized: "quickEntry.sheet.more.hint"))
        }
    }

    private var typeSelection: Binding<TransactionType> {
        Binding(
            get: { model.draft.type == .income ? .income : .expense },
            set: { type in
                if hapticEnabled { HapticManager.selection() }
                model.setType(type)
            }
        )
    }

    // MARK: - Field

    private var entrySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                TextField(
                    String(localized: "quickEntry.sheet.field"),
                    text: $model.text,
                    prompt: Text(String(localized: "quickEntry.sheet.placeholder"))
                )
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                // Amount first is the common case: open on the digits, one
                // tap away from letters.
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.sentences)
                .submitLabel(.done)
                .focused($isFieldFocused)
                .onSubmit {
                    if model.canSave {
                        Task { await save() }
                    } else {
                        isFieldFocused = true
                    }
                }
                .accessibilityHint(String(localized: "quickEntry.sheet.field.hint"))

                micButton
            }
            Text(summaryText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(summaryAccessibilityLabel)
                .animation(nil, value: model.text)
        }
    }

    private var micButton: some View {
        let listening = model.speech.isListening
        return Button {
            if listening {
                model.stopVoice()
            } else {
                isFieldFocused = false
                Task { await model.startVoice() }
            }
        } label: {
            Image(systemName: listening ? "stop.fill" : "mic.fill")
                .font(.title3.weight(.semibold))
                .frame(width: 28, height: 28)
                .symbolEffect(.pulse, options: .repeating, isActive: listening && !reduceMotion)
        }
        .buttonStyle(.akifiSecondary)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .tint(listening ? Color.expense : Color.accent)
        .disabled(model.speech.state == .requestingPermission)
        .accessibilityLabel(listening ? String(localized: "quickEntry.sheet.mic.stop") : String(localized: "quickEntry.sheet.mic.start"))
    }

    private var summaryText: AttributedString {
        guard !model.isEmpty else {
            return AttributedString(String(localized: "quickEntry.sheet.hint"))
        }
        let summary = model.summary
        var out = AttributedString()
        func append(_ text: String, style: (inout AttributedString) -> Void = { _ in }) {
            if !out.characters.isEmpty { out += AttributedString(" · ") }
            var part = AttributedString(text)
            style(&part)
            out += part
        }
        if let title = summary.title { append(title) { $0.foregroundColor = .primary } }
        if let amount = summary.amount {
            append(amount) {
                $0.foregroundColor = .primary
                $0.font = .subheadline.weight(.semibold)
            }
        } else {
            append(String(localized: "quickEntry.sheet.summary.noAmount")) { $0.foregroundColor = Color.warning }
        }
        append(summary.date)
        if let account = summary.account { append(account) }
        return out
    }

    private var summaryAccessibilityLabel: String {
        guard !model.isEmpty else { return String(localized: "quickEntry.sheet.hint") }
        let summary = model.summary
        return [summary.title, summary.amount ?? String(localized: "quickEntry.sheet.summary.noAmount"), summary.date, summary.account]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    // MARK: - Voice status

    private func voiceStatusRow(_ status: QuickEntryVoiceStatus) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: voiceStatusSymbol(status))
                .font(.body.weight(.semibold))
                .foregroundStyle(status == .listening ? Color.expense : (status.fallsBackToTyping ? Color.warning : Color.secondary))
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: status == .listening && !reduceMotion)
                .accessibilityHidden(true)
            Text(voiceStatusText(status))
                .font(.subheadline)
                .foregroundStyle(status == .listening ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if status.offersSettings {
                Button(String(localized: "common.settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func voiceStatusSymbol(_ status: QuickEntryVoiceStatus) -> String {
        switch status {
        case .requestingPermission: "lock.shield"
        case .listening: "waveform"
        case .deniedMicrophone, .deniedSpeech, .restricted: "mic.slash"
        case .unavailable, .failed: "exclamationmark.bubble"
        }
    }

    private func voiceStatusText(_ status: QuickEntryVoiceStatus) -> String {
        switch status {
        case .requestingPermission: String(localized: "quickEntry.sheet.voice.permission")
        case .listening: String(localized: "quickEntry.sheet.voice.listening")
        case .deniedMicrophone: String(localized: "quickEntry.sheet.voice.deniedMicrophone")
        case .deniedSpeech: String(localized: "quickEntry.sheet.voice.deniedSpeech")
        case .restricted: String(localized: "quickEntry.sheet.voice.restricted")
        case .unavailable: String(localized: "quickEntry.sheet.voice.unavailable")
        case .failed: String(localized: "quickEntry.sheet.voice.failed")
        }
    }

    // MARK: - Categories

    @ViewBuilder
    private var categoryRow: some View {
        let chips = model.categoryChips
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips) { chip in
                        Button {
                            chooseCategory(chip.category)
                        } label: {
                            QuickEntryChipLabel(icon: chip.category.icon, title: chip.category.name, isSelected: chip.isSelected)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(chip.isSelected ? .isSelected : [])
                        .accessibilityHint(model.draft.amount != nil ? String(localized: "quickEntry.sheet.category.saveHint") : "")
                    }
                    Button {
                        showCategoryPicker = true
                    } label: {
                        QuickEntryChipLabel(systemImage: "square.grid.2x2", title: String(localized: "quickEntry.sheet.categories.all"), isSelected: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "quickEntry.sheet.categories.all.a11y"))
                }
                .padding(.horizontal, 20)
            }
            .padding(.horizontal, -20)
            .scrollClipDisabled()
        }
    }

    private func chooseCategory(_ category: Category) {
        if hapticEnabled { HapticManager.selection() }
        let complete = model.chooseCategory(category.id)
        // Amount → category = done; without an amount the tap only picks.
        if complete {
            Task { await save() }
        }
    }

    // MARK: - Account and date

    private var accountAndDateRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                accountMenu
                dateMenu
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                accountMenu
                dateMenu
            }
        }
    }

    private var accountMenu: some View {
        Menu {
            Picker(String(localized: "common.account"), selection: Binding(
                get: { model.draft.accountId ?? "" },
                set: { id in
                    if hapticEnabled { HapticManager.selection() }
                    model.chooseAccount(id)
                }
            )) {
                ForEach(model.accounts) { account in
                    Text(verbatim: "\(account.icon) \(account.name)").tag(account.id)
                }
            }
        } label: {
            if let account = model.account {
                QuickEntryChipLabel(icon: account.icon, title: account.name, isSelected: false, showsChevron: true)
            } else {
                QuickEntryChipLabel(systemImage: "creditcard", title: String(localized: "quickEntry.error.noAccount"), isSelected: false, showsChevron: true, isWarning: true)
            }
        }
        .disabled(model.accounts.isEmpty)
        .accessibilityLabel(String(format: String(localized: "quickEntry.sheet.account.a11y"), model.account?.name ?? String(localized: "quickEntry.error.noAccount")))
    }

    private var dateMenu: some View {
        Menu {
            Button(String(localized: "date.today")) { chooseDay(0) }
            Button(String(localized: "date.yesterday")) { chooseDay(-1) }
            Button(String(localized: "quickEntry.sheet.date.dayBefore")) { chooseDay(-2) }
            Divider()
            Button {
                showDatePicker = true
            } label: {
                Label(String(localized: "quickEntry.sheet.date.other"), systemImage: "calendar")
            }
        } label: {
            QuickEntryChipLabel(systemImage: "calendar", title: model.dateChipLabel, isSelected: false, showsChevron: true)
        }
        .accessibilityLabel(String(format: String(localized: "quickEntry.sheet.date.a11y"), model.dateChipLabel))
    }

    private func chooseDay(_ offset: Int) {
        if hapticEnabled { HapticManager.selection() }
        model.chooseDay(offset: offset)
    }

    private var datePickerSheet: some View {
        NavigationStack {
            DatePicker(
                String(localized: "common.date"),
                selection: Binding(get: { model.draft.date }, set: { model.chooseDate($0) }),
                displayedComponents: [.date]
            )
            .datePickerStyle(.graphical)
            .padding(.horizontal)
            .navigationTitle(String(localized: "common.date"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.done")) { showDatePicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.showsRepeatStrip {
                repeatStrip
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Color.expense)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Task { await save() }
            } label: {
                ZStack {
                    Text(String(localized: "common.save"))
                        .font(.headline)
                        .opacity(model.isSaving ? 0 : 1)
                    if model.isSaving {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 28)
            }
            .buttonStyle(.akifiPrimary)
            .controlSize(.large)
            .disabled(!model.canSave)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var repeatStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "quickEntry.sheet.repeat"))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.repeatCandidates) { item in
                        Button {
                            if hapticEnabled { HapticManager.light() }
                            model.applyRepeat(item)
                        } label: {
                            QuickEntryChipLabel(
                                icon: repeatIcon(item),
                                title: repeatTitle(item),
                                isSelected: model.appliedRepeatId == item.id
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(repeatAccessibilityLabel(item))
                        .accessibilityAddTraits(model.appliedRepeatId == item.id ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.horizontal, -20)
            .scrollClipDisabled()
        }
    }

    private func repeatIcon(_ item: QuickEntryRepeatItem) -> String? {
        model.context.displayCategory(item.categoryId)?.icon
    }

    private func repeatTitle(_ item: QuickEntryRepeatItem) -> String {
        let name = item.description.isEmpty ? (model.context.displayCategory(item.categoryId)?.name ?? "") : item.description
        let amount = TransactionFormView.formatRawAmount(item.amount, currency: CurrencyCode(code: item.currencyCode) ?? CurrencyCode(unchecked: item.currencyCode))
        return name.isEmpty ? amount : "\(name) · \(amount)"
    }

    private func repeatAccessibilityLabel(_ item: QuickEntryRepeatItem) -> String {
        let account = model.context.account(item.accountId)?.name ?? ""
        let details = [repeatTitle(item).replacingOccurrences(of: " · ", with: ", "), account].filter { !$0.isEmpty }.joined(separator: ", ")
        return String(format: String(localized: "quickEntry.sheet.repeat.a11y"), details)
    }

    // MARK: - Actions

    private func start() async {
        if model.startsWithVoice {
            await model.startVoice()
        } else {
            // The sheet is still animating in; focus a beat later or the
            // keyboard doesn't come up.
            try? await Task.sleep(for: .milliseconds(150))
            isFieldFocused = true
        }
    }

    private func save(confirmed: Bool = false) async {
        switch await model.save(confirmingLargeExpense: confirmed) {
        case .saved(let saved):
            if hapticEnabled { HapticManager.success() }
            onSaved(saved)
        case .needsLargeExpenseConfirmation(let decision):
            if hapticEnabled { HapticManager.warning() }
            largeExpense = decision
        case .failed:
            if hapticEnabled { HapticManager.error() }
        case .notReady:
            break
        }
    }

    /// Same text as the form's large-expense alert.
    private func largeExpenseMessage(_ decision: TransactionGuards.LargeExpenseDecision) -> String {
        let cm = appViewModel.currencyManager
        let median = cm.formatInCurrency(decision.medianInBaseDisplay, currency: cm.dataCurrency)
        return String(
            format: String(localized: "transaction.confirmLargeExpense.message"),
            QuickEntryIntentSupport.amountText(model.draft),
            median
        )
    }
}

// MARK: - Chip

/// A selectable capsule of the sheet (category, account, date, repeat).
/// Content, not glass: the sheet itself is the glass layer.
struct QuickEntryChipLabel: View {
    var icon: String?
    var systemImage: String?
    var title: String
    var isSelected: Bool
    var showsChevron = false
    var isWarning = false

    var body: some View {
        HStack(spacing: 6) {
            if let icon, !icon.isEmpty {
                Text(verbatim: icon)
                    .accessibilityHidden(true)
            }
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            Text(verbatim: title)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
            }
        }
        .font(.subheadline.weight(isSelected ? .semibold : .medium))
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : (isWarning ? AnyShapeStyle(Color.warning) : AnyShapeStyle(.primary)))
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(isSelected ? AnyShapeStyle(Color.accent) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
        .contentShape(Capsule())
    }
}

/// Keeps the open sheet's snapshot in step with the store (first load
/// finishing after a cold start from a quick action, a sync) without making
/// the sheet's own body depend on every transaction.
private struct QuickEntryStoreObserver: View {
    @Environment(AppViewModel.self) private var appViewModel
    let model: QuickEntrySheetModel

    private var signature: String {
        let store = appViewModel.dataStore
        return "\(store.accounts.map(\.id))|\(store.displayCategories.count)|\(store.transactions.count)|\(store.transactions.first?.id ?? "")"
    }

    var body: some View {
        Color.clear
            .onChange(of: signature) { _, _ in
                model.updateContext(QuickEntryContext(dataStore: appViewModel.dataStore, currencyManager: appViewModel.currencyManager))
            }
            .accessibilityHidden(true)
    }
}
