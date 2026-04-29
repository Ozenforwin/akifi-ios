import SwiftUI

/// Sheet form for creating/editing an `InvestmentHolding`. Reachable
/// from `InvestmentHoldingsListView` (embedded inside `AssetFormView`)
/// and from `PortfolioDashboardView`'s "+ Add position" button.
///
/// The form requires a parent Asset to attach to. When the caller
/// already knows the asset (e.g. the user opens the form from inside
/// an investment Asset's editor), it passes `initialAssetId` and the
/// picker collapses to a static label. Otherwise the picker shows
/// every Asset of category `.investment` / `.crypto`; if there are
/// none, the form shows an empty-state nudging the user to create
/// the parent first.
///
/// Quantity and last price are typed as Decimal — the user can enter
/// 0.00012345 BTC without losing precision. Cost basis is Int64 minor
/// units of the parent Asset's currency, parsed the same way as
/// `AssetFormView`.
///
/// Sprint 3 will plug a "Pull current price" button into the lastPrice
/// row that calls `PriceFeedService`. For now the field is manual.
struct InvestmentHoldingFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppViewModel.self) private var appViewModel

    let onSave: (CreateHoldingInput) async -> Void
    let onUpdate: ((String, UpdateHoldingInput) async -> Void)?
    let editingHolding: InvestmentHolding?
    /// Pre-selects the parent Asset. When nil, the picker is shown.
    let initialAssetId: String?
    /// All Assets eligible to host a holding (category investment/crypto).
    /// Passed in by the caller — we don't fetch here so the form stays
    /// a pure leaf view.
    let parentAssets: [Asset]

    @State private var assetId: String = ""
    @State private var ticker: String = ""
    @State private var kind: HoldingKind = .etf
    @State private var quantityText: String = ""
    @State private var costBasisText: String = ""
    @State private var lastPriceText: String = ""
    @State private var lastPriceDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var notes: String = ""
    @State private var isSaving = false

    init(parentAssets: [Asset],
         initialAssetId: String? = nil,
         editingHolding: InvestmentHolding? = nil,
         onSave: @escaping (CreateHoldingInput) async -> Void,
         onUpdate: ((String, UpdateHoldingInput) async -> Void)? = nil) {
        self.parentAssets = parentAssets
        self.initialAssetId = initialAssetId
        self.editingHolding = editingHolding
        self.onSave = onSave
        self.onUpdate = onUpdate
    }

    private var isEditing: Bool { editingHolding != nil }

    /// The Asset this holding belongs to — we need its currency to
    /// label the cost-basis and price fields properly.
    private var parentAsset: Asset? {
        parentAssets.first { $0.id == assetId }
    }

    private var currencyLabel: String {
        parentAsset?.currency.uppercased() ?? "—"
    }

    private var isValid: Bool {
        guard !assetId.isEmpty,
              !ticker.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let qty = parseDecimal(quantityText)
        let price = parseDecimal(lastPriceText)
        return qty > 0 && price >= 0
    }

    var body: some View {
        NavigationStack {
            Group {
                if parentAssets.isEmpty {
                    emptyParentsState
                } else {
                    formBody
                }
            }
            .navigationTitle(isEditing
                             ? String(localized: "holding.form.title.edit")
                             : String(localized: "holding.form.title.new"))
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
            .onAppear { prefill() }
        }
    }

    // MARK: - Form sections

    @ViewBuilder
    private var formBody: some View {
        Form {
            Section(String(localized: "holding.form.section.position")) {
                if initialAssetId == nil && !isEditing {
                    Picker(String(localized: "holding.form.parentAsset"), selection: $assetId) {
                        ForEach(parentAssets, id: \.id) { asset in
                            Text("\(asset.icon ?? asset.category.symbol.first.map(String.init) ?? "📊") \(asset.name)").tag(asset.id)
                        }
                    }
                } else if let asset = parentAsset {
                    HStack {
                        Text(String(localized: "holding.form.parentAsset"))
                        Spacer()
                        Text(asset.name)
                            .foregroundStyle(.secondary)
                    }
                }

                TextField(String(localized: "holding.form.ticker"), text: $ticker)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)

                Picker(String(localized: "holding.form.kind"), selection: $kind) {
                    ForEach(HoldingKind.allCases, id: \.self) { k in
                        Label(k.localizedTitle, systemImage: k.symbol).tag(k)
                    }
                }
            }

            Section(String(localized: "holding.form.section.amount")) {
                HStack {
                    TextField(String(localized: "holding.form.quantity"), text: $quantityText)
                        .keyboardType(.decimalPad)
                    Text(String(localized: "holding.form.units"))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                HStack {
                    TextField(String(localized: "holding.form.costBasis"), text: $costBasisText)
                        .keyboardType(.decimalPad)
                    Text(currencyLabel)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            Section(
                header: Text(String(localized: "holding.form.section.price")),
                footer: Text(String(localized: "holding.form.priceFooter"))
            ) {
                HStack {
                    TextField(String(localized: "holding.form.lastPrice"), text: $lastPriceText)
                        .keyboardType(.decimalPad)
                    Text(currencyLabel)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                DatePicker(
                    String(localized: "holding.form.lastPriceDate"),
                    selection: $lastPriceDate,
                    displayedComponents: .date
                )
            }

            Section(String(localized: "holding.form.notes")) {
                TextField(String(localized: "holding.form.notes.placeholder"),
                          text: $notes, axis: .vertical)
                    .lineLimit(2...6)
            }
        }
    }

    @ViewBuilder
    private var emptyParentsState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(String(localized: "holding.form.empty.title"))
                .font(.headline)
            Text(String(localized: "holding.form.empty.subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Save

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let qty = parseDecimal(quantityText)
        let cost = parseKopecks(costBasisText)
        let price = parseDecimal(lastPriceText)
        let dateStr = NetWorthSnapshotRepository.dateFormatter.string(from: lastPriceDate)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNotes = trimmedNotes.isEmpty ? nil : trimmedNotes
        let cleanTicker = ticker.trimmingCharacters(in: .whitespaces).uppercased()

        if let editing = editingHolding, let onUpdate {
            let update = UpdateHoldingInput(
                ticker: cleanTicker,
                kind: kind,
                quantity: qty,
                costBasis: cost,
                lastPrice: price,
                lastPriceDate: dateStr,
                notes: cleanNotes
            )
            await onUpdate(editing.id, update)
        } else {
            let userId = (try? await SupabaseManager.shared.currentUserId()) ?? ""
            let input = CreateHoldingInput(
                userId: userId,
                assetId: assetId,
                ticker: cleanTicker,
                kind: kind,
                quantity: qty,
                costBasis: cost,
                lastPrice: price,
                lastPriceDate: dateStr,
                notes: cleanNotes
            )
            await onSave(input)
        }

        HapticManager.success()
        dismiss()
    }

    // MARK: - Parsing

    /// Accepts "1234.56", "1 234,56" — same rules as `AssetFormView`.
    private func parseDecimal(_ text: String) -> Decimal {
        let cleaned = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return Decimal(string: cleaned) ?? 0
    }

    private func parseKopecks(_ text: String) -> Int64 {
        let value = parseDecimal(text)
        var product = value * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &product, 0, .plain)
        return Int64(truncating: rounded as NSDecimalNumber)
    }

    // MARK: - Prefill

    private func prefill() {
        if let h = editingHolding {
            assetId = h.assetId
            ticker = h.ticker
            kind = h.kind
            quantityText = decimalString(h.quantity)
            costBasisText = kopecksString(h.costBasis,
                                          decimals: parentAsset?.currencyCode.decimals ?? 2)
            lastPriceText = decimalString(h.lastPrice)
            if let d = NetWorthSnapshotRepository.dateFormatter.date(from: h.lastPriceDate) {
                lastPriceDate = d
            }
            notes = h.notes ?? ""
        } else {
            // New: pick the supplied or first parent asset by default.
            if let initial = initialAssetId, parentAssets.contains(where: { $0.id == initial }) {
                assetId = initial
            } else if let first = parentAssets.first {
                assetId = first.id
            }
        }
    }

    private func decimalString(_ value: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 8
        f.minimumFractionDigits = 0
        f.groupingSeparator = ""
        f.decimalSeparator = "."
        return f.string(from: value as NSDecimalNumber) ?? ""
    }

    private func kopecksString(_ kopecks: Int64, decimals: Int) -> String {
        let value = Decimal(kopecks) / 100
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = decimals
        f.minimumFractionDigits = 0
        f.groupingSeparator = ""
        f.decimalSeparator = "."
        return f.string(from: value as NSDecimalNumber) ?? ""
    }
}
