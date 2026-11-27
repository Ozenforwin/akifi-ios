import SwiftUI

struct BudgetCardView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let budget: Budget
    let metrics: BudgetMetrics
    let categories: [Category]
    /// The budget's categories as the server sees them — a partner can't
    /// load the owner's personal categories (RLS), so without these the card
    /// read «Все категории» on the partner's phone (B1).
    var serverCategories: [ServerBudgetMetrics.CategoryRef] = []
    /// A partner's latest spending may be missing (server unreachable, B5).
    var isPartial: Bool = false

    // MARK: - Formatters

    private static let forecastFormatter: DateFormatter = {
        let df = DateFormatter() // date-formatter-ok: display, follows user locale
        df.locale = Locale.current
        df.calendar = Calendar(identifier: .gregorian)
        df.setLocalizedDateFormatFromTemplate("d MMM")
        return df
    }()

    // MARK: - Shared budget members

    private var sharedMembers: [BudgetMember] {
        appViewModel.dataStore.budgetMembersByBudget[budget.id] ?? []
    }

    /// Overlapping initials circles — shown only when the budget actually
    /// has more than one member.
    private var memberAvatarStack: some View {
        HStack(spacing: -6) {
            ForEach(sharedMembers.prefix(3)) { member in
                memberInitialsCircle(member.userId)
            }
        }
        .accessibilityLabel(String(localized: "share.members"))
    }

    @ScaledMetric(relativeTo: .caption2) private var memberAvatarSize: CGFloat = 20

    private func memberInitialsCircle(_ userId: String) -> some View {
        let profile = appViewModel.dataStore.profilesMap[userId]
        let initial = String((profile?.fullName ?? profile?.email ?? "?").prefix(1)).uppercased()
        return Circle()
            .fill(Color(.systemGray4))
            .frame(width: memberAvatarSize, height: memberAvatarSize)
            .overlay {
                Text(verbatim: initial)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            }
            .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 1.5))
    }

    // MARK: - Computed Properties

    private var progressColor: Color { Color(hex: metrics.progressColor) }

    /// (name, icon) of every budget category: local rows first, the
    /// server's for ids this phone can't see.
    private var budgetCategoryLabels: [(name: String, icon: String)] {
        guard let catIds = budget.categories, !catIds.isEmpty else { return [] }
        let localById = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let serverById = Dictionary(serverCategories.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        return catIds.compactMap { id in
            if let local = localById[id] { return (local.name, local.icon) }
            if let remote = serverById[id.lowercased()] { return (remote.name, remote.icon ?? "") }
            return nil
        }
    }

    private var categoryNames: String {
        let names = budgetCategoryLabels.map(\.name)
        return names.isEmpty ? String(localized: "budget.allCategories") : names.joined(separator: ", ")
    }

    private var categoryIcons: String {
        let labels = budgetCategoryLabels
        guard !labels.isEmpty else { return "📊" }
        return labels.map(\.icon).prefix(3).joined()
    }

    private var statusLabel: (text: String, color: Color) {
        switch metrics.status {
        case .onTrack: return (String(localized: "budget.status.onTrack"), .green)
        case .warning: return (String(localized: "budget.status.warning"), Color.warning)
        case .nearLimit: return (String(localized: "budget.status.nearLimit"), .orange)
        case .overLimit: return (String(localized: "budget.status.overLimit"), .red)
        }
    }

    private var paceDescription: String {
        switch metrics.paceRatio {
        case ..<0.9: return String(localized: "budget.pace.underPace")
        case 0.9..<1.1: return String(localized: "budget.pace.onTrack")
        case 1.1..<1.3: return String(localized: "budget.pace.slightlyOver")
        default: return String(localized: "budget.pace.overPace")
        }
    }

    private var paceColor: Color {
        metrics.paceRatio <= 1.1 ? .green : Color.warning
    }

    /// The window the numbers cover (D4): a 30-day rolling budget made on
    /// the 19th reads «19 окт – 17 ноя», not «Ноябрь 2026». Same window as
    /// the server and the push.
    private var periodLabel: String {
        if metrics.periodStart != .distantPast {
            return BudgetsViewModel.periodLabel(start: metrics.periodStart, end: metrics.periodEnd)
        }
        let period = BudgetMath.currentPeriod(for: budget)
        return BudgetsViewModel.periodLabel(start: period.start, end: period.end)
    }

    private var forecastDate: Date? {
        BudgetMath.forecastOverrunDate(metrics: metrics)
    }

    private var fmt: CurrencyManager { appViewModel.currencyManager }

    /// Formats `kopecks` in the **budget's** currency, not the user's
    /// display currency. With explicit `budget.currency` we want a USD
    /// budget to read as "$120 / $200" even when the user's display ccy
    /// is RUB; otherwise the card silently FX-converts and stops matching
    /// the value the user typed in. Legacy budgets (currency == nil) keep
    /// the old behavior — base-ccy amount converted to display ccy.
    /// Rendered without cents: against a monthly limit the fractional part
    /// is noise, and "2 916 653 ₫ из 3 000 000 ₫" has to stay readable.
    private func budgetFmt(_ kopecks: Int64) -> String {
        if let raw = budget.currency,
           let code = Currency(code: raw.uppercased()) {
            return fmt.formatInCurrency(abs(kopecks).displayAmount, currency: code, wholeUnits: true)
        }
        return fmt.formatAmount(kopecks.displayAmount, wholeUnits: true)
    }

    // MARK: - Accessibility

    private var accessibilityDescription: String {
        let status = statusLabel.text
        let spent = budgetFmt(metrics.spent)
        let limit = budgetFmt(metrics.effectiveLimit)
        let remaining = budgetFmt(max(0, metrics.remaining))
        let pct = metrics.utilization
        return "\(budget.name). \(status). \(spent) \(String(localized: "common.of")) \(limit), \(pct)%. \(remaining) \(String(localized: "budget.accessibility.remaining"))."
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: icon + name + type badge + status pill
            HStack(spacing: 10) {
                Text(categoryIcons)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(budget.name)
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: budget.budgetTypeEnum.icon)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(categoryNames) · \(periodLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Overlapping member avatars for shared budgets
                if sharedMembers.count > 1 {
                    memberAvatarStack
                }

                // Status pill — foreground uses .primary for contrast
                Text(statusLabel.text)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusLabel.color.opacity(0.15))
                    .clipShape(Capsule())
            }

            // Progress bar — 12pt height with subscription segment + threshold marker
            GeometryReader { geo in
                let spentWidth = geo.size.width * min(CGFloat(metrics.utilization) / 100, 1.0)
                let subPct = metrics.effectiveLimit > 0
                    ? CGFloat(metrics.subscriptionCommitted) / CGFloat(metrics.effectiveLimit)
                    : 0
                let subWidth = min(geo.size.width - spentWidth, geo.size.width * min(subPct, 1.0))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.systemGray5))

                    HStack(spacing: 0) {
                        Capsule()
                            .fill(progressColor)
                            .frame(width: spentWidth)
                            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8), value: metrics.utilization)

                        if metrics.subscriptionCommitted > 0 && subWidth > 0 {
                            Capsule()
                                .fill(Color.budget.opacity(0.35))
                                .frame(width: subWidth)
                                .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8), value: metrics.subscriptionCommitted)
                        }
                    }

                    // 80% threshold tick
                    Rectangle()
                        .fill(Color(.systemGray3))
                        .frame(width: 2, height: 16)
                        .offset(x: geo.size.width * 0.8 - 1)
                }
            }
            .frame(height: 12)
            .accessibilityHidden(true)

            // Stats row: spent / remaining + pace + utilization %
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(budgetFmt(metrics.spent))")
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(progressColor)
                    + Text(" \(String(localized: "common.of")) \(budgetFmt(metrics.effectiveLimit))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Pace — contextual label
                Text(paceDescription)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(paceColor)

                Text("\(metrics.utilization)%")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(progressColor)
            }

            // Subscription committed row
            if metrics.subscriptionCommitted > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "repeat.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.budget)
                    Text(String(localized: "budget.subscriptions.\(budgetFmt(metrics.subscriptionCommitted))"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(String(localized: "budget.freeRemaining.\(budgetFmt(metrics.freeRemaining))"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            // Safe-to-spend daily + remaining days
            if metrics.remainingDays > 0 && metrics.remaining > 0 {
                HStack(spacing: 16) {
                    Label {
                        Text("\(budgetFmt(metrics.safeToSpendDaily))/\(String(localized: "budget.perDay"))")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "shield.checkered")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    Label {
                        Text(String(localized: "budget.daysRemaining.\(metrics.remainingDays)"))
                            .font(.caption)
                    } icon: {
                        Image(systemName: "calendar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.secondary)
            } else if metrics.remaining <= 0 {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text(String(localized: "budget.exceeded.\(budgetFmt(abs(metrics.remaining)))"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                }
            }

            if isPartial {
                HStack(spacing: 6) {
                    Image(systemName: "icloud.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(localized: "budget.partial.hint",
                                defaultValue: "Траты участников могут быть неполными — нет связи с сервером"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Forecast overrun warning
            if let overrun = forecastDate, metrics.remaining > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(String(localized: "budget.forecastOverrun.\(Self.forecastFormatter.string(from: overrun))"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                }
            }
        }
        // Plain content card. Status is carried by the pill, the bar and
        // the warning rows — no status-tinted fill, material or shadow.
        .akifiCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint(String(localized: "budget.accessibility.swipeToEdit"))
        .contextMenu {
            Button {
                // Edit action handled by parent view
            } label: {
                Label(String(localized: "common.edit"), systemImage: "pencil")
            }
            Button(role: .destructive) {
                // Archive action handled by parent view
            } label: {
                Label(String(localized: "budget.archive"), systemImage: "archivebox")
            }
        }
    }
}
