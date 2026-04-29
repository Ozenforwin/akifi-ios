import SwiftUI
import Charts

/// Top-level investor surface for the BETA "Активы → инвестиции" path.
/// Shows the aggregate portfolio (across every Asset of category
/// investment / crypto), a donut for allocation by kind, a second
/// donut for currency exposure, and a flat list of every holding
/// cross-asset.
///
/// Owns its own `PortfolioViewModel` (via `@State`). Loads on
/// `.task` and again on pull-to-refresh.
struct PortfolioDashboardView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = PortfolioViewModel()
    @State private var showForm = false
    @State private var editingHolding: InvestmentHolding?

    private var dataStore: DataStore { appViewModel.dataStore }
    private var cm: CurrencyManager { appViewModel.currencyManager }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCard
                if viewModel.holdings.isEmpty {
                    emptyState
                } else {
                    allocationCard(
                        title: String(localized: "portfolio.allocation.byKind"),
                        slices: kindSlices
                    )
                    allocationCard(
                        title: String(localized: "portfolio.allocation.byCurrency"),
                        slices: currencySlices
                    )
                    holdingsListCard
                }
            }
            .padding(16)
            .padding(.bottom, 120)
        }
        .navigationTitle(String(localized: "portfolio.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showForm = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(viewModel.assetsForPortfolio.isEmpty)
            }
        }
        .task {
            await viewModel.load(currencyManager: cm)
        }
        .refreshable {
            await viewModel.load(currencyManager: cm)
        }
        .sheet(isPresented: $showForm) {
            InvestmentHoldingFormView(
                parentAssets: viewModel.assetsForPortfolio,
                onSave: { input in
                    await viewModel.create(input, currencyManager: cm)
                }
            )
            .presentationBackground(.ultraThinMaterial)
        }
        .sheet(item: $editingHolding) { h in
            InvestmentHoldingFormView(
                parentAssets: viewModel.assetsForPortfolio,
                initialAssetId: h.assetId,
                editingHolding: h,
                onSave: { _ in /* unused for edit */ },
                onUpdate: { id, input in
                    await viewModel.update(id: id, input, currencyManager: cm)
                }
            )
            .presentationBackground(.ultraThinMaterial)
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var heroCard: some View {
        let summary = viewModel.summary ?? .zero
        let total = summary.totalValue
        let pnl = summary.unrealizedPnL
        let isPositive = pnl >= 0
        let pnlColor: Color = isPositive ? Color(hex: "#16A34A") : Color(hex: "#DC2626")

        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "portfolio.hero.title"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            Text(cm.formatAmount(total.displayAmount))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .minimumScaleFactor(0.55)
                .lineLimit(1)

            HStack(spacing: 6) {
                Image(systemName: isPositive ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption.weight(.bold))
                Text(pnlLine(pnl: pnl, roi: summary.roi))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(pnlColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.accent.opacity(0.08), Color.accent.opacity(0.16)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.accent.opacity(0.18), lineWidth: 0.5)
        )
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.pie")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(String(localized: "portfolio.empty.title"))
                .font(.headline)
            Text(viewModel.assetsForPortfolio.isEmpty
                 ? String(localized: "portfolio.empty.noParents")
                 : String(localized: "portfolio.empty.subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            if !viewModel.assetsForPortfolio.isEmpty {
                Button {
                    showForm = true
                } label: {
                    Label(String(localized: "holding.list.add"),
                          systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accent)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - Allocation donut

    /// One slice on the allocation chart. `id` is the localized title
    /// — both donuts in this view key by string (HoldingKind for one,
    /// currency code for the other).
    private struct AllocationSlice: Identifiable {
        let id: String
        let label: String
        let amount: Int64
        let color: String
        var percentage: Double = 0
    }

    private var kindSlices: [AllocationSlice] {
        let total = viewModel.summary?.totalValue ?? 0
        guard total > 0 else { return [] }
        let raw = viewModel.summary?.byKind ?? [:]
        return raw.sorted { $0.value > $1.value }.map { kind, amount in
            AllocationSlice(
                id: "kind-\(kind.rawValue)",
                label: kind.localizedTitle,
                amount: amount,
                color: kind.defaultHex,
                percentage: Double(amount) / Double(total) * 100
            )
        }
    }

    private var currencySlices: [AllocationSlice] {
        let total = viewModel.summary?.totalValue ?? 0
        guard total > 0 else { return [] }
        let raw = viewModel.summary?.byCurrency ?? [:]
        // Stable colour per currency — pick the first 7 hex slots from
        // HoldingKind so the two donuts share a visual palette.
        let palette = ["#60A5FA", "#4ADE80", "#FBBF24", "#A78BFA", "#F472B6",
                       "#94A3B8", "#9CA3AF", "#FB923C", "#34D399"]
        return raw.sorted { $0.value > $1.value }.enumerated().map { (idx, pair) in
            AllocationSlice(
                id: "ccy-\(pair.key)",
                label: pair.key,
                amount: pair.value,
                color: palette[idx % palette.count],
                percentage: Double(pair.value) / Double(total) * 100
            )
        }
    }

    @ViewBuilder
    private func allocationCard(title: String, slices: [AllocationSlice]) -> some View {
        if slices.isEmpty {
            EmptyView()
        } else {
            allocationCardBody(title: title, slices: slices)
        }
    }

    @ViewBuilder
    private func allocationCardBody(title: String, slices: [AllocationSlice]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            HStack(alignment: .top, spacing: 16) {
                Chart(slices) { slice in
                    SectorMark(
                        angle: .value("amount", slice.amount),
                        innerRadius: .ratio(0.55),
                        angularInset: 1.5
                    )
                    .foregroundStyle(Color(hex: slice.color))
                    .cornerRadius(4)
                }
                .frame(width: 140, height: 140)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(slices.prefix(6)) { slice in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color(hex: slice.color))
                                .frame(width: 8, height: 8)
                            Text(slice.label)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(String(format: "%.1f%%", slice.percentage))
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    if slices.count > 6 {
                        Text("+\(slices.count - 6) \(String(localized: "common.more"))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
        )
    }

    // MARK: - Holdings list

    @ViewBuilder
    private var holdingsListCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "portfolio.holdings.title"))
                    .font(.headline)
                Spacer()
                Text("\(viewModel.holdings.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            VStack(spacing: 0) {
                ForEach(viewModel.holdings) { h in
                    crossAssetRow(h)
                        .contentShape(Rectangle())
                        .onTapGesture { editingHolding = h }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await viewModel.delete(holding: h, currencyManager: cm) }
                            } label: {
                                Label(String(localized: "common.delete"), systemImage: "trash")
                            }
                        }
                    if h.id != viewModel.holdings.last?.id {
                        Divider().padding(.leading, 56)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }

    @ViewBuilder
    private func crossAssetRow(_ h: InvestmentHolding) -> some View {
        let parent = viewModel.assetsForPortfolio.first { $0.id == h.assetId }
        HStack(spacing: 12) {
            Image(systemName: h.kind.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color(hex: h.kind.defaultHex))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(h.ticker)
                    .font(.subheadline.weight(.semibold))
                if let parent {
                    Text(parent.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(formatLocal(h.currentValueMinor, currency: parent?.currency ?? "USD"))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                if let roi = PortfolioCalculator.roi(for: h) {
                    Text(roiLabel(roi))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(roi >= 0 ? Color(hex: "#16A34A") : Color(hex: "#DC2626"))
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Formatting

    private func pnlLine(pnl: Int64, roi: Decimal?) -> String {
        let abs = Swift.abs(pnl)
        let amt = cm.formatAmount(abs.displayAmount)
        let sign = pnl >= 0 ? "+" : "−"
        guard let roi else { return "\(sign)\(amt)" }
        let pct = NSDecimalNumber(decimal: roi * 100).doubleValue
        return String(format: "%@%@ · %+.1f%%", sign, amt, pct)
    }

    private func formatLocal(_ minor: Int64, currency: String) -> String {
        let code = CurrencyCode(rawValue: currency.uppercased()) ?? .rub
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = code.decimals
        f.minimumFractionDigits = code.decimals
        f.groupingSeparator = " "
        let value = minor.displayAmount
        let str = f.string(from: value as NSDecimalNumber) ?? "0"
        return "\(str) \(code.symbol)"
    }

    private func roiLabel(_ roi: Decimal) -> String {
        let pct = NSDecimalNumber(decimal: roi * 100).doubleValue
        let sign = pct >= 0 ? "+" : ""
        return String(format: "%@%.1f%%", sign, pct)
    }
}
