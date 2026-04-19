import SwiftUI

/// Sectioned list of the user's liabilities grouped by category. Same
/// interaction model as AssetListView (swipe-to-delete, tap-to-edit, +
/// toolbar button).
struct LiabilityListView: View {
    @Bindable var viewModel: NetWorthViewModel
    var initialCategory: LiabilityCategory?

    @Environment(AppViewModel.self) private var appViewModel
    @State private var showForm = false
    @State private var editingLiability: Liability?

    private var dataStore: DataStore { appViewModel.dataStore }
    private var cm: CurrencyManager { appViewModel.currencyManager }

    init(viewModel: NetWorthViewModel, initialCategory: LiabilityCategory? = nil) {
        self.viewModel = viewModel
        self.initialCategory = initialCategory
    }

    var body: some View {
        List {
            if viewModel.liabilities.isEmpty {
                emptyState
            } else {
                ForEach(groupedSections, id: \.0) { category, items in
                    Section(category.localizedTitle) {
                        ForEach(items) { liability in
                            liabilityRow(liability)
                                .contentShape(Rectangle())
                                .onTapGesture { editingLiability = liability }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task {
                                            await viewModel.deleteLiability(
                                                id: liability.id,
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
        .navigationTitle(String(localized: "netWorth.liabilities.title"))
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
            LiabilityFormView(
                initialCategory: initialCategory,
                onSave: { input in
                    await viewModel.createLiability(input, dataStore: dataStore, currencyManager: cm)
                }
            )
            .presentationBackground(.ultraThinMaterial)
        }
        .sheet(item: $editingLiability) { liability in
            LiabilityFormView(
                editingLiability: liability,
                onSave: { _ in /* unused for edit */ },
                onUpdate: { id, input in
                    await viewModel.updateLiability(id: id, input, dataStore: dataStore, currencyManager: cm)
                }
            )
            .presentationBackground(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private func liabilityRow(_ liability: Liability) -> some View {
        HStack(spacing: 12) {
            Image(systemName: liability.icon ?? liability.category.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color(hex: liability.color ?? liability.category.defaultHex))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(liability.name)
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 4) {
                    if let rate = liability.interestRate, rate > 0 {
                        Text(String(format: "%.2f%%", rate))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let rate = liability.interestRate, rate > 0,
                       let monthly = liability.monthlyPayment, monthly > 0 {
                        Text("·").font(.caption2).foregroundStyle(.tertiary)
                    }
                    if let monthly = liability.monthlyPayment, monthly > 0 {
                        Text("\(formatLocal(monthly, currency: liability.currency))/\(String(localized: "liability.perMonth"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("-\(formatLocal(liability.currentBalance, currency: liability.currency))")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color(hex: "#DC2626"))
                Text(liability.currency.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "creditcard.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(String(localized: "netWorth.liabilities.empty.title"))
                .font(.headline)
            Text(String(localized: "netWorth.liabilities.empty.subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showForm = true
            } label: {
                Label(String(localized: "netWorth.liabilities.add"), systemImage: "plus.circle.fill")
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

    private var groupedSections: [(LiabilityCategory, [Liability])] {
        let grouped = Dictionary(grouping: viewModel.liabilities, by: \.category)
        let order: [LiabilityCategory] = [
            .mortgage, .loan, .creditCard, .personalDebt, .other
        ]
        return order.compactMap { cat in
            guard let items = grouped[cat], !items.isEmpty else { return nil }
            return (cat, items)
        }
    }

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
