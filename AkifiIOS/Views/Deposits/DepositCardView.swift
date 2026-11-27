import SwiftUI

/// One deposit as a list row: status tile, name, status pill, principal +
/// accrued total and a caption with rate + time-left to maturity. Sits in
/// an inset-grouped `List`, which provides the row background.
struct DepositCardView: View {
    let deposit: Deposit
    /// Display title — usually the tied account's name.
    let title: String
    /// Live total value (principal + accrued) in deposit kopecks.
    let totalValue: Int64
    /// Kopecks of accrued interest (for the "+N" caption).
    let accrued: Int64
    let currency: CurrencyCode
    /// Days remaining until maturity. Nil → open-ended. Negative → overdue.
    let daysToMaturity: Int?

    init(deposit: Deposit,
         title: String? = nil,
         totalValue: Int64,
         accrued: Int64,
         currency: CurrencyCode,
         daysToMaturity: Int?) {
        self.deposit = deposit
        self.title = title ?? String(localized: "deposit.item.title")
        self.totalValue = totalValue
        self.accrued = accrued
        self.currency = currency
        self.daysToMaturity = daysToMaturity
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            SettingsIconTile(systemName: statusIcon, color: statusColor)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    statusPill
                }
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(formatAmount(totalValue))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                if accrued > 0 {
                    Text("+\(formatAmount(accrued))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.income)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var statusIcon: String {
        switch deposit.status {
        case .active:      return "percent"
        case .matured:     return "checkmark.seal.fill"
        case .closedEarly: return "xmark.seal.fill"
        }
    }

    /// Status carries meaning: running (budget violet), paid out (income
    /// green), closed early (neutral).
    private var statusColor: Color {
        switch deposit.status {
        case .active:      return Color.budget
        case .matured:     return Color.income
        case .closedEarly: return Color(.systemGray)
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        Text(deposit.status.localizedTitle)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor.opacity(colorScheme == .dark ? 0.22 : 0.12), in: Capsule())
            .foregroundStyle(statusColor)
    }

    private var caption: String {
        let rateStr = formatRate(deposit.interestRate)
        let freqStr = deposit.compoundFrequency.localizedTitle
        if let days = daysToMaturity, deposit.status == .active {
            if days > 0 {
                let daysStr = String(
                    format: NSLocalizedString("deposit.daysLeft", comment: ""),
                    days
                )
                return "\(rateStr) · \(freqStr) · \(daysStr)"
            } else if days == 0 {
                return "\(rateStr) · \(freqStr) · \(String(localized: "deposit.maturesToday"))"
            } else {
                return "\(rateStr) · \(freqStr) · \(String(localized: "deposit.overdue"))"
            }
        }
        return "\(rateStr) · \(freqStr)"
    }

    private func formatAmount(_ kopecks: Int64) -> String {
        let decimal = Decimal(kopecks) / 100
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = currency.decimals
        f.minimumFractionDigits = 0
        f.groupingSeparator = " "
        let formatted = f.string(from: decimal as NSDecimalNumber) ?? "0"
        return "\(formatted) \(currency.symbol)"
    }

    private func formatRate(_ rate: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        f.decimalSeparator = "."
        let s = f.string(from: rate as NSDecimalNumber) ?? "0"
        return "\(s)%"
    }
}
