import SwiftUI

/// Compact list of holdings tied to a single Asset. Used as an
/// embedded section inside `AssetFormView` for category investment /
/// crypto, and inside `PortfolioDashboardView`'s per-asset rows.
///
/// The list reads holdings from the supplied `viewModel`, filters
/// down to those with `assetId == asset.id`, and renders one row per
/// position with ticker / quantity / current value / ROI. Tapping a
/// row opens the editor; swipe-left deletes; the trailing "+" button
/// opens the create sheet.
///
/// Stale-price awareness: holdings whose `lastPriceDate` is more than
/// 30 days behind today get a small "stale" chip. Sprint 3 lights it
/// up in red and adds a "Pull current price" affordance.
struct InvestmentHoldingsListView: View {
    @Bindable var viewModel: PortfolioViewModel
    let asset: Asset

    @Environment(AppViewModel.self) private var appViewModel
    @State private var showForm = false
    @State private var editingHolding: InvestmentHolding?

    private var cm: CurrencyManager { appViewModel.currencyManager }

    private var holdings: [InvestmentHolding] {
        viewModel.holdings.filter { $0.assetId == asset.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "holding.list.title"))
                    .font(.headline)
                Spacer()
                Button {
                    showForm = true
                } label: {
                    Label(String(localized: "holding.list.add"), systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accent)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
            }

            if holdings.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(holdings) { h in
                        holdingRow(h)
                            .contentShape(Rectangle())
                            .onTapGesture { editingHolding = h }
                        if h.id != holdings.last?.id {
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
        .sheet(isPresented: $showForm) {
            InvestmentHoldingFormView(
                parentAssets: viewModel.assetsForPortfolio,
                initialAssetId: asset.id,
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

    // MARK: - Rows

    @ViewBuilder
    private func holdingRow(_ h: InvestmentHolding) -> some View {
        HStack(spacing: 12) {
            Image(systemName: h.kind.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color(hex: h.kind.defaultHex))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(h.ticker)
                        .font(.subheadline.weight(.semibold))
                    if h.isStale() {
                        staleChip
                    }
                }
                Text(quantityLine(h))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(formatLocal(h.currentValueMinor, currency: asset.currency))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                if let roi = PortfolioCalculator.roi(for: h) {
                    let cagr = acquiredDate.flatMap { date in
                        PortfolioCalculator.cagr(for: h, acquiredDate: date)
                    }
                    Text(roiAndCagrLabel(roi: roi, cagr: cagr))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(roi >= 0 ? Color(hex: "#16A34A") : Color(hex: "#DC2626"))
                        .monospacedDigit()
                } else {
                    Text("—")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task { await viewModel.delete(holding: h, currencyManager: cm) }
            } label: {
                Label(String(localized: "common.delete"), systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var staleChip: some View {
        Text(String(localized: "holding.stale"))
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.warning)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.warning.opacity(0.15))
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(String(localized: "holding.list.empty.title"))
                .font(.subheadline.weight(.medium))
            Text(String(localized: "holding.list.empty.subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - Formatting

    /// "10 units" / "0.5 BTC" depending on kind. Quantity formatted
    /// with up to 8 decimals, trailing zeros trimmed.
    private func quantityLine(_ h: InvestmentHolding) -> String {
        let qty = formatQuantity(h.quantity)
        let unit = h.kind == .crypto ? h.ticker : String(localized: "holding.form.units")
        return "\(qty) \(unit)"
    }

    private func formatQuantity(_ value: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 8
        f.minimumFractionDigits = 0
        f.groupingSeparator = " "
        return f.string(from: value as NSDecimalNumber) ?? "0"
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

    /// "+12.5%" / "−4.2%". Percentage with one fraction digit.
    private func roiLabel(_ roi: Decimal) -> String {
        let pct = NSDecimalNumber(decimal: roi * 100).doubleValue
        let sign = pct >= 0 ? "+" : ""
        return String(format: "%@%.1f%%", sign, pct)
    }

    /// "+12.5% · +6.1%/yr" — total ROI plus annualised CAGR when the
    /// position has been held long enough (≥30 days, parent asset has
    /// `acquiredDate`). Falls back to total ROI alone otherwise.
    private func roiAndCagrLabel(roi: Decimal, cagr: Decimal?) -> String {
        let total = roiLabel(roi)
        guard let cagr else { return total }
        let pct = NSDecimalNumber(decimal: cagr * 100).doubleValue
        let sign = pct >= 0 ? "+" : ""
        return String(format: "%@ · %@%.1f%%/\(String(localized: "common.year.short"))", total, sign, pct)
    }

    /// Earliest acquired-date among parent Assets that contain a
    /// holding under this list. Used to estimate CAGR — `nil` when the
    /// parent has no acquired date set.
    private var acquiredDate: Date? {
        guard let dateStr = asset.acquiredDate else { return nil }
        return NetWorthSnapshotRepository.dateFormatter.date(from: dateStr)
    }
}
