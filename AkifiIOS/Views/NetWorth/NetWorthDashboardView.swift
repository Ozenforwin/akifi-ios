import SwiftUI
import Charts

/// Hero screen for the net-worth tracker. Shows:
/// - big monospaced net-worth hero (green positive / red negative)
/// - 3-row breakdown (accounts / assets / liabilities)
/// - Swift Charts line with history (period picker: 30/90/180/365 d)
/// - grouped assets and liabilities sections with NavigationLinks
///
/// Entry points: HomeTabView shortcut card, Settings → Finance section.
struct NetWorthDashboardView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var viewModel = NetWorthViewModel()
    @State private var showAssetForm = false
    @State private var showLiabilityForm = false
    @State private var chartPeriod: ChartPeriod = .ninetyDays

    private var dataStore: DataStore { appViewModel.dataStore }
    private var cm: CurrencyManager { appViewModel.currencyManager }

    /// History-chart window selector. Raw values are days.
    enum ChartPeriod: Int, CaseIterable, Identifiable {
        case thirtyDays = 30
        case ninetyDays = 90
        case halfYear = 180
        case year = 365

        var id: Int { rawValue }
        var localizedLabel: String {
            switch self {
            case .thirtyDays: return String(localized: "netWorth.history.period.30d")
            case .ninetyDays: return String(localized: "netWorth.history.period.90d")
            case .halfYear:   return String(localized: "netWorth.history.period.180d")
            case .year:       return String(localized: "netWorth.history.period.365d")
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCard
                breakdownCard
                fireTeaserCard
                historySection
                assetsSection
                liabilitiesSection
            }
            .padding(16)
            .padding(.bottom, 120)
        }
        .navigationTitle(String(localized: "netWorth.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load(dataStore: dataStore, currencyManager: cm)
        }
        .refreshable {
            await viewModel.load(dataStore: dataStore, currencyManager: cm)
        }
        .sheet(isPresented: $showAssetForm) {
            AssetFormView(
                onSave: { input in
                    try await viewModel.createAsset(input, dataStore: dataStore, currencyManager: cm)
                }
            )
            .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showLiabilityForm) {
            LiabilityFormView(
                onSave: { input in
                    await viewModel.createLiability(input, dataStore: dataStore, currencyManager: cm)
                }
            )
            .presentationBackground(.ultraThinMaterial)
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var heroCard: some View {
        let breakdown = viewModel.breakdown ?? .zero
        let netWorth = breakdown.netWorth
        let isPositive = netWorth >= 0
        let tint: Color = isPositive ? Color(hex: "#16A34A") : Color(hex: "#DC2626")
        let subtitleKey: String = isPositive ? "netWorth.hero.subtitle.positive" : "netWorth.hero.subtitle.negative"

        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "netWorth.hero.title"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            Text(formatHeroAmount(netWorth))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
                .minimumScaleFactor(0.55)
                .lineLimit(1)

            Text(String(localized: String.LocalizationValue(subtitleKey)))
                .font(.footnote)
                .foregroundStyle(.secondary)

            // Formula strip: makes the source of the number obvious so users
            // don't wonder "откуда эта сумма". Composition = accounts + assets
            // − liabilities, matching the breakdown card below.
            Text(formulaText(for: breakdown))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.08), tint.opacity(0.16)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 0.5)
        )
    }

    // MARK: - Breakdown

    @ViewBuilder
    private var breakdownCard: some View {
        let breakdown = viewModel.breakdown ?? .zero
        VStack(spacing: 0) {
            breakdownRow(
                title: String(localized: "netWorth.breakdown.accounts"),
                symbol: "wallet.pass.fill",
                color: Color.accent,
                amount: breakdown.accountsTotal,
                signed: false
            )
            Divider().padding(.leading, 56)
            breakdownRow(
                title: String(localized: "netWorth.breakdown.assets"),
                symbol: "building.2.fill",
                color: Color(hex: "#16A34A"),
                amount: breakdown.assetsTotal,
                signed: false
            )
            Divider().padding(.leading, 56)
            breakdownRow(
                title: String(localized: "netWorth.breakdown.liabilities"),
                symbol: "creditcard.fill",
                color: Color(hex: "#DC2626"),
                amount: breakdown.liabilitiesTotal,
                signed: true
            )
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func breakdownRow(title: String, symbol: String, color: Color, amount: Int64, signed: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(color)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            Text(title)
                .font(.subheadline.weight(.medium))

            Spacer()

            Text(signed ? "-\(cm.formatAmount(amount.displayAmount))" : cm.formatAmount(amount.displayAmount))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(signed ? Color(hex: "#DC2626") : .primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - FIRE teaser

    /// Single-row tease card linking to `FIREProjectionView`. Hidden
    /// until `viewModel.fireSnippet.hasEnoughData == true` so we
    /// don't show meaningless numbers during onboarding.
    @ViewBuilder
    private var fireTeaserCard: some View {
        if let snippet = viewModel.fireSnippet, snippet.hasEnoughData {
            NavigationLink {
                FIREProjectionView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(
                            LinearGradient(
                                colors: [Color.accent, Color.accent.opacity(0.78)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "fire.teaser.title"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let years = snippet.yearsToFIRE {
                            let pct = NSDecimalNumber(decimal: years).doubleValue
                            Text(String(format: String(localized: "fire.teaser.yearsFormat"), pct))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else {
                            Text(String(localized: "fire.teaser.unreachable"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.accent.opacity(0.18), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - History chart

    @ViewBuilder
    private var historySection: some View {
        let series = filteredSnapshots
        if series.count >= 1 {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(String(localized: "netWorth.history.title"))
                        .font(.headline)
                    Spacer()
                    Picker("", selection: $chartPeriod) {
                        ForEach(ChartPeriod.allCases) { period in
                            Text(period.localizedLabel).tag(period)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.secondary)
                }

                Chart(series) { point in
                    LineMark(
                        x: .value("date", point.date),
                        y: .value("netWorth", Double(point.netWorth) / 100.0)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.accent.gradient)

                    AreaMark(
                        x: .value("date", point.date),
                        y: .value("netWorth", Double(point.netWorth) / 100.0)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accent.opacity(0.25), Color.accent.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                .frame(height: 180)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: false)
                            .font(.caption2)
                        AxisGridLine()
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine()
                    }
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
    }

    /// Snapshot points within the currently-selected window, oldest→newest.
    private var filteredSnapshots: [SnapshotPoint] {
        let cal = Calendar(identifier: .gregorian)
        let cutoff = cal.date(byAdding: .day, value: -chartPeriod.rawValue, to: Date()) ?? Date()
        let parser = NetWorthSnapshotRepository.dateFormatter
        return viewModel.snapshots
            .compactMap { snap -> SnapshotPoint? in
                guard let date = parser.date(from: snap.snapshotDate),
                      date >= cutoff else { return nil }
                return SnapshotPoint(id: snap.id, date: date, netWorth: snap.netWorth)
            }
            .sorted { $0.date < $1.date }
    }

    // MARK: - Assets section

    @ViewBuilder
    private var assetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(localized: "netWorth.assets.title"))
                    .font(.headline)
                Spacer()
                NavigationLink {
                    AssetListView(viewModel: viewModel)
                } label: {
                    Text(String(localized: "common.all"))
                        .font(.subheadline)
                        .foregroundStyle(Color.accent)
                }
            }

            if viewModel.assets.isEmpty {
                Button {
                    showAssetForm = true
                } label: {
                    addButton(title: String(localized: "netWorth.assets.empty.cta"),
                              symbol: "plus.circle.fill",
                              tint: Color(hex: "#16A34A"))
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(groupedAssets), id: \.0) { category, total in
                        NavigationLink {
                            AssetListView(viewModel: viewModel, initialCategory: category)
                        } label: {
                            categoryRow(
                                title: category.localizedTitle,
                                symbol: category.symbol,
                                hex: category.defaultHex,
                                total: total,
                                negative: false
                            )
                        }
                        .buttonStyle(.plain)
                        if category != groupedAssets.last?.0 {
                            Divider().padding(.leading, 56)
                        }
                    }

                    Divider().padding(.leading, 56)

                    Button {
                        showAssetForm = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.accent)
                            Text(String(localized: "netWorth.assets.add"))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.accent)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
                )
            }
        }
    }

    // MARK: - Liabilities section

    @ViewBuilder
    private var liabilitiesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(localized: "netWorth.liabilities.title"))
                    .font(.headline)
                Spacer()
                NavigationLink {
                    LiabilityListView(viewModel: viewModel)
                } label: {
                    Text(String(localized: "common.all"))
                        .font(.subheadline)
                        .foregroundStyle(Color.accent)
                }
            }

            if viewModel.liabilities.isEmpty {
                Button {
                    showLiabilityForm = true
                } label: {
                    addButton(title: String(localized: "netWorth.liabilities.empty.cta"),
                              symbol: "plus.circle.fill",
                              tint: Color(hex: "#DC2626"))
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(groupedLiabilities), id: \.0) { category, total in
                        NavigationLink {
                            LiabilityListView(viewModel: viewModel, initialCategory: category)
                        } label: {
                            categoryRow(
                                title: category.localizedTitle,
                                symbol: category.symbol,
                                hex: category.defaultHex,
                                total: total,
                                negative: true
                            )
                        }
                        .buttonStyle(.plain)
                        if category != groupedLiabilities.last?.0 {
                            Divider().padding(.leading, 56)
                        }
                    }

                    Divider().padding(.leading, 56)

                    Button {
                        showLiabilityForm = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.accent)
                            Text(String(localized: "netWorth.liabilities.add"))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.accent)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
                )
            }
        }
    }

    @ViewBuilder
    private func categoryRow(title: String, symbol: String, hex: String, total: Int64, negative: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color(hex: hex))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            Text(title)
                .font(.subheadline.weight(.medium))

            Spacer()

            Text(negative ? "-\(cm.formatAmount(total.displayAmount))" : cm.formatAmount(total.displayAmount))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(negative ? Color(hex: "#DC2626") : .primary)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func addButton(title: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 0.5)
        )
    }

    private var groupedAssets: [(AssetCategory, Int64)] {
        let raw = viewModel.breakdown?.byAssetCategory ?? [:]
        return raw.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    private var groupedLiabilities: [(LiabilityCategory, Int64)] {
        let raw = viewModel.breakdown?.byLiabilityCategory ?? [:]
        return raw.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    /// Larger monospaced digits with the currency symbol kept small — same
    /// typographic treatment as AccountCarouselView hero but less aggressive
    /// (since the net-worth value can span 8-10 digits).
    private func formatHeroAmount(_ amount: Int64) -> String {
        let absAmount = abs(amount)
        let formatted = cm.formatAmount(absAmount.displayAmount)
        return amount < 0 ? "-\(formatted)" : formatted
    }

    /// Literal composition of the net-worth number. Example RU:
    /// "Счета 2 631 940 ₽ + Активы 0 ₽ − Долги 0 ₽".
    /// Shown under the hero subtitle so users immediately see where the
    /// value comes from (most common question when assets/liabilities
    /// are empty and net worth equals account balance).
    private func formulaText(for breakdown: NetWorthCalculator.Breakdown) -> String {
        let accounts = cm.formatAmount(breakdown.accountsTotal.displayAmount)
        let assets = cm.formatAmount(breakdown.assetsTotal.displayAmount)
        let liabilities = cm.formatAmount(breakdown.liabilitiesTotal.displayAmount)
        let accountsLabel = String(localized: "netWorth.breakdown.accounts")
        let assetsLabel = String(localized: "netWorth.breakdown.assets")
        let liabilitiesLabel = String(localized: "netWorth.breakdown.liabilities")
        return "\(accountsLabel) \(accounts) + \(assetsLabel) \(assets) − \(liabilitiesLabel) \(liabilities)"
    }
}

/// Lightweight chart point — plotting `NetWorthSnapshot` directly would
/// push the Date parsing into Swift Charts, which it handles awkwardly.
private struct SnapshotPoint: Identifiable {
    let id: String
    let date: Date
    let netWorth: Int64
}
