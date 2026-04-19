import SwiftUI

/// Sectioned list of the user's assets grouped by category. Swipe-to-
/// delete, tap-to-edit, FAB for new. Can be reached via:
/// - NetWorthDashboardView → "All" or category row
/// - SettingsView → Finance → Активы
struct AssetListView: View {
    @Bindable var viewModel: NetWorthViewModel
    var initialCategory: AssetCategory?

    @Environment(AppViewModel.self) private var appViewModel
    @State private var showForm = false
    @State private var editingAsset: Asset?

    private var dataStore: DataStore { appViewModel.dataStore }
    private var cm: CurrencyManager { appViewModel.currencyManager }

    init(viewModel: NetWorthViewModel, initialCategory: AssetCategory? = nil) {
        self.viewModel = viewModel
        self.initialCategory = initialCategory
    }

    var body: some View {
        List {
            if viewModel.assets.isEmpty {
                emptyState
            } else {
                ForEach(groupedSections, id: \.0) { category, items in
                    Section(category.localizedTitle) {
                        ForEach(items) { asset in
                            assetRow(asset)
                                .contentShape(Rectangle())
                                .onTapGesture { editingAsset = asset }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task {
                                            await viewModel.deleteAsset(
                                                id: asset.id,
                                                dataStore: dataStore,
                                                currencyManager: cm
                                            )
                                        }
                                    } label: {
                                        Label(String(localized: "common.delete"), systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "netWorth.assets.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showForm = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showForm) {
            AssetFormView(
                initialCategory: initialCategory,
                onSave: { input in
                    await viewModel.createAsset(input, dataStore: dataStore, currencyManager: cm)
                }
            )
            .presentationBackground(.ultraThinMaterial)
        }
        .sheet(item: $editingAsset) { asset in
            AssetFormView(
                editingAsset: asset,
                onSave: { _ in /* unused for edit */ },
                onUpdate: { id, input in
                    await viewModel.updateAsset(id: id, input, dataStore: dataStore, currencyManager: cm)
                }
            )
            .presentationBackground(.ultraThinMaterial)
        }
    }

    // MARK: - Rows & Sections

    @ViewBuilder
    private func assetRow(_ asset: Asset) -> some View {
        HStack(spacing: 12) {
            Image(systemName: asset.icon ?? asset.category.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color(hex: asset.color ?? asset.category.defaultHex))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(asset.name)
                    .font(.subheadline.weight(.medium))
                if let notes = asset.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(formatLocal(asset.currentValue, currency: asset.currency))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(asset.currency.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "building.2.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(String(localized: "netWorth.assets.empty.title"))
                .font(.headline)
            Text(String(localized: "netWorth.assets.empty.subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showForm = true
            } label: {
                Label(String(localized: "netWorth.assets.add"), systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }

    private var groupedSections: [(AssetCategory, [Asset])] {
        let grouped = Dictionary(grouping: viewModel.assets, by: \.category)
        // Stable, eye-pleasing order roughly matching enum definition order.
        let order: [AssetCategory] = [
            .realEstate, .vehicle, .investment, .crypto, .cash, .collectible, .other
        ]
        return order.compactMap { cat in
            guard let items = grouped[cat], !items.isEmpty else { return nil }
            return (cat, items)
        }
    }

    /// Show the amount in the asset's native currency for per-row display
    /// (so the user always sees what they actually entered). Dashboard
    /// sums convert to base currency separately.
    private func formatLocal(_ amount: Int64, currency: String) -> String {
        let code = CurrencyCode(rawValue: currency.uppercased()) ?? .rub
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = code.decimals
        formatter.minimumFractionDigits = code.decimals
        let value = amount.displayAmount
        let str = formatter.string(from: value as NSDecimalNumber) ?? "0"
        return "\(str) \(code.symbol)"
    }
}
