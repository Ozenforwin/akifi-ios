import SwiftUI

struct BudgetCardView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let budget: Budget
    let metrics: BudgetMetrics
    let categories: [Category]

    // MARK: - Formatters

    private static let forecastFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "d MMM"
        df.locale = Locale.current
        return df
    }()

    // MARK: - Computed Properties

    private var progressColor: Color { Color(hex: metrics.progressColor) }

    private var progressGradient: LinearGradient {
        LinearGradient(
            colors: [progressColor.opacity(0.7), progressColor],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var categoryNames: String {
        guard let catIds = budget.categories, !catIds.isEmpty else {
            return String(localized: "budget.allCategories")
        }
        let names = categories.filter { catIds.contains($0.id) }.map(\.name)
        return names.isEmpty ? String(localized: "budget.allCategories") : names.joined(separator: ", ")
    }

    private var categoryIcons: String {
        guard let catIds = budget.categories, !catIds.isEmpty else { return "📊" }
        return categories.filter { catIds.contains($0.id) }.map(\.icon).prefix(3).joined()
    }

    private var statusLabel: (text: String, color: Color) {
        switch metrics.status {
        case .onTrack: return (String(localized: "budget.status.onTrack"), .green)
        case .warning: return (String(localized: "budget.status.warning"), Color.warning)
        case .nearLimit: return (String(localized: "budget.status.nearLimit"), .orange)
        case .overLimit: return (String(localized: "budget.status.overLimit"), .red)
        }
    }

    private var cardTintColor: Color {
        switch metrics.status {
        case .onTrack: return .clear
        case .warning: return Color.warning.opacity(0.05)
        case .nearLimit: return Color.orange.opacity(0.07)
        case .overLimit: return Color.red.opacity(0.08)
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

    private var periodLabel: String {
        let cal = Calendar.current
        let df = DateFormatter()
        df.locale = Locale.current
        switch budget.billingPeriod {
        case .weekly:
            let period = BudgetMath.currentPeriod(for: budget)
            df.dateFormat = "d MMM"
            return "\(df.string(from: period.start)) – \(df.string(from: period.end))"
        case .monthly:
            df.dateFormat = "LLLL yyyy"
            return df.string(from: Date()).capitalized
        case .quarterly:
            let month = cal.component(.month, from: Date())
            let quarter = (month - 1) / 3 + 1
            let year = cal.component(.year, from: Date())
            return "\(String(localized: "budget.quarter")) \(quarter), \(year)"
        case .yearly:
            return String(cal.component(.year, from: Date()))
        case .custom:
            let period = BudgetMath.currentPeriod(for: budget)
            df.dateFormat = "d MMM yyyy"
            return "\(df.string(from: period.start)) – \(df.string(from: period.end))"
        }
    }

    private var forecastDate: Date? {
        BudgetMath.forecastOverrunDate(metrics: metrics)
    }

    private var fmt: CurrencyManager { appViewModel.currencyManager }

    // MARK: - Accessibility

    private var accessibilityDescription: String {
        let status = statusLabel.text
        let spent = fmt.formatAmount(metrics.spent.displayAmount)
        let limit = fmt.formatAmount(metrics.effectiveLimit.displayAmount)
        let remaining = fmt.formatAmount(max(0, metrics.remaining).displayAmount)
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

                // Status pill — foreground uses .primary for contrast
                Text(statusLabel.text)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusLabel.color.opacity(0.15))
                    .clipShape(Capsule())
            }

            // Progress bar — 12pt height with threshold marker
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.systemGray5))

                    Capsule()
                        .fill(progressGradient)
                        .frame(width: geo.size.width * min(CGFloat(metrics.utilization) / 100, 1.0))
                        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8), value: metrics.utilization)

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
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(fmt.formatAmount(metrics.spent.displayAmount))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(progressColor)
                    + Text(" \(String(localized: "common.of")) \(fmt.formatAmount(metrics.effectiveLimit.displayAmount))")
                        .font(.caption)
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

            // Safe-to-spend daily + remaining days
            if metrics.remainingDays > 0 && metrics.remaining > 0 {
                HStack(spacing: 16) {
                    Label {
                        Text("\(fmt.formatAmount(metrics.safeToSpendDaily.displayAmount))/\(String(localized: "budget.perDay"))")
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
                    Text(String(localized: "budget.exceeded.\(fmt.formatAmount(abs(metrics.remaining).displayAmount))"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
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
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(cardTintColor)
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
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
