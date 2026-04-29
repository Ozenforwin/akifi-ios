import SwiftUI

/// Create/edit form for a single asset. Used as a sheet from both the
/// dashboard (+ button) and AssetListView (+ toolbar / tap on row).
///
/// The form is deliberately light — category-picker with iconography,
/// decimal-pad amount input, currency menu, optional notes and acquired
/// date. Icon/color overrides are deferred to a future polish pass; the
/// category's default SF Symbol + hex are used by default.
struct AssetFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppViewModel.self) private var appViewModel

    /// Called on save for create flow. For edit flow, `onUpdate` is used
    /// instead so the caller can route to `repo.update(id:)`. Both can
    /// throw — the form catches and surfaces the message in an alert
    /// instead of dismissing on a silent backend reject.
    let onSave: (CreateAssetInput) async throws -> Void
    let onUpdate: ((String, UpdateAssetInput) async throws -> Void)?
    let editingAsset: Asset?
    let initialCategory: AssetCategory?

    @State private var name: String = ""
    @State private var category: AssetCategory = .realEstate
    @State private var amountText: String = ""
    @State private var currency: CurrencyCode = .rub
    @State private var notes: String = ""
    @State private var hasAcquiredDate: Bool = false
    @State private var acquiredDate: Date = Date()
    @State private var isSaving = false

    /// Independent VM for the embedded holdings list. Only loads when
    /// the form is editing an `investment` / `crypto` Asset — otherwise
    /// the section never renders so the network round-trip is skipped.
    @State private var portfolioVM = PortfolioViewModel()
    @State private var holdingsLoaded = false

    /// Server-side error captured during save. Non-nil keeps the form
    /// open so the user sees what to fix (RLS reject, FK failure,
    /// validation message); the alert below clears it on dismiss.
    @State private var saveError: String?

    /// True when the embedded "Positions" section should appear:
    /// editing an existing Asset of category investment/crypto. On
    /// create the user has no `assetId` yet, so positions can only be
    /// added after the first save.
    private var supportsHoldings: Bool {
        guard editingAsset != nil else { return false }
        return category == .investment || category == .crypto
    }

    init(initialCategory: AssetCategory? = nil,
         editingAsset: Asset? = nil,
         onSave: @escaping (CreateAssetInput) async throws -> Void,
         onUpdate: ((String, UpdateAssetInput) async throws -> Void)? = nil) {
        self.initialCategory = initialCategory
        self.editingAsset = editingAsset
        self.onSave = onSave
        self.onUpdate = onUpdate
    }

    private var isEditing: Bool { editingAsset != nil }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (Decimal(string: amountText.replacingOccurrences(of: ",", with: ".")) ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "asset.form.section.info")) {
                    TextField(String(localized: "asset.form.name"), text: $name)
                    categoryPicker
                }

                Section(String(localized: "asset.form.section.value")) {
                    HStack {
                        TextField(String(localized: "asset.form.value"), text: $amountText)
                            .keyboardType(.decimalPad)
                        Picker("", selection: $currency) {
                            ForEach(CurrencyCode.allCases, id: \.self) { code in
                                Text("\(code.symbol) \(code.rawValue)").tag(code)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.secondary)
                    }
                }

                Section {
                    Toggle(String(localized: "asset.form.hasAcquiredDate"), isOn: $hasAcquiredDate.animation())
                    if hasAcquiredDate {
                        DatePicker(
                            String(localized: "asset.form.acquiredDate"),
                            selection: $acquiredDate,
                            displayedComponents: .date
                        )
                    }
                }

                Section(String(localized: "asset.form.notes")) {
                    TextField(String(localized: "asset.form.notes.placeholder"), text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                }

                if supportsHoldings, let editing = editingAsset {
                    Section {
                        InvestmentHoldingsListView(viewModel: portfolioVM, asset: editing)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    } header: {
                        Text(String(localized: "asset.form.section.positions"))
                    } footer: {
                        Text(String(localized: "asset.form.positionsFooter"))
                    }
                }
            }
            .navigationTitle(isEditing
                             ? String(localized: "asset.form.title.edit")
                             : String(localized: "asset.form.title.new"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "common.save")) {
                        Task { await save() }
                    }
                    .disabled(!isValid || isSaving)
                }
            }
            .onAppear {
                prefillForEditing()
                if supportsHoldings && !holdingsLoaded {
                    holdingsLoaded = true
                    Task { await portfolioVM.load(currencyManager: appViewModel.currencyManager) }
                }
            }
            .alert(
                String(localized: "asset.form.saveError.title"),
                isPresented: Binding(
                    get: { saveError != nil },
                    set: { if !$0 { saveError = nil } }
                ),
                presenting: saveError
            ) { _ in
                Button(String(localized: "common.ok"), role: .cancel) { saveError = nil }
            } message: { detail in
                Text(detail)
            }
        }
    }

    // MARK: - Category picker

    @ViewBuilder
    private var categoryPicker: some View {
        Picker(String(localized: "asset.form.category"), selection: $category) {
            ForEach(AssetCategory.allCases, id: \.self) { cat in
                Label(cat.localizedTitle, systemImage: cat.symbol)
                    .tag(cat)
            }
        }
    }

    // MARK: - Persistence

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let kopecks = parseKopecks(amountText)
        let acquiredString: String? = hasAcquiredDate
            ? NetWorthSnapshotRepository.dateFormatter.string(from: acquiredDate)
            : nil
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        if let editing = editingAsset, let onUpdate {
            let update = UpdateAssetInput(
                name: name,
                category: category.rawValue,
                current_value: kopecks,
                currency: currency.rawValue,
                icon: nil,
                color: nil,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                acquired_date: acquiredString
            )
            do {
                try await onUpdate(editing.id, update)
            } catch {
                HapticManager.error()
                saveError = error.localizedDescription
                return
            }
        } else {
            // user_id is optional on the wire; let the DB DEFAULT auth.uid()
            // fill it if our session is fresh and currentUserId() returns "".
            let userId = (try? await SupabaseManager.shared.currentUserId()) ?? ""
            let input = CreateAssetInput(
                user_id: userId.isEmpty ? nil : userId,
                name: name,
                category: category.rawValue,
                current_value: kopecks,
                currency: currency.rawValue,
                icon: nil,
                color: nil,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                acquired_date: acquiredString
            )
            do {
                try await onSave(input)
            } catch {
                HapticManager.error()
                saveError = error.localizedDescription
                return
            }
        }

        HapticManager.success()
        dismiss()
    }

    /// Parses the user's input (accepts "1234.56", "1 234,56", etc.) into
    /// Int64 kopecks. Commas are treated as decimal separators.
    private func parseKopecks(_ text: String) -> Int64 {
        let cleaned = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard let decimal = Decimal(string: cleaned) else { return 0 }
        let kopecks = decimal * 100
        var rounded = Decimal()
        var src = kopecks
        NSDecimalRound(&rounded, &src, 0, .plain)
        return Int64(truncating: rounded as NSDecimalNumber)
    }

    /// When an editingAsset is provided, populate the form state from it.
    /// Runs in `onAppear` to avoid mutating `@State` during view init.
    private func prefillForEditing() {
        if let asset = editingAsset {
            name = asset.name
            category = asset.category
            amountText = Self.formatAmountForInput(asset.currentValue, decimals: asset.currencyCode.decimals)
            currency = asset.currencyCode
            notes = asset.notes ?? ""
            if let dateStr = asset.acquiredDate,
               let date = NetWorthSnapshotRepository.dateFormatter.date(from: dateStr) {
                hasAcquiredDate = true
                acquiredDate = date
            }
        } else {
            // Fresh form: honor caller's preferred category + use the user's
            // base currency so most-common paths are one-tap.
            if let initial = initialCategory {
                category = initial
            }
            currency = appViewModel.currencyManager.dataCurrency
        }
    }

    private static func formatAmountForInput(_ kopecks: Int64, decimals: Int) -> String {
        let decimal = Decimal(kopecks) / 100
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = decimals
        f.minimumFractionDigits = 0
        f.groupingSeparator = ""
        f.decimalSeparator = "."
        return f.string(from: decimal as NSDecimalNumber) ?? ""
    }
}
