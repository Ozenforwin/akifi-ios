import SwiftUI

struct PortfolioChartView: View {
    @Environment(AppViewModel.self) private var appViewModel

    private var dataStore: DataStore { appViewModel.dataStore }

    private var portfolioData: [(account: Account, balance: Decimal)] {
        dataStore.accounts.map { account in
            (account, dataStore.balance(for: account).displayAmount)
        }
        .sorted { $0.balance > $1.balance }
    }

    private var totalBalance: Decimal {
        portfolioData.reduce(.zero) { $0 + $1.balance }
    }

    private var totalPositive: Decimal {
        portfolioData.reduce(.zero) { $0 + max(0, $1.balance) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "analytics.portfolio"))
                    .font(.headline)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "creditcard")
                        .font(.caption)
                    Text(String(localized: "analytics.allBalances"))
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            // Total balance with sign
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(formattedTotal)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(totalBalance < 0 ? Color.expense : .primary)
            }

            // Stacked progress bar — only positive balances
            if totalPositive > 0 {
                GeometryReader { geo in
                    HStack(spacing: 1.5) {
                        ForEach(portfolioData, id: \.account.id) { item in
                            if item.balance > 0 {
                                let pct = CGFloat(truncating: (item.balance / totalPositive) as NSDecimalNumber)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(hex: item.account.color).gradient)
                                    .frame(width: max(4, geo.size.width * pct))
                            }
                        }
                    }
                }
                .frame(height: 8)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            // Account list
            if !portfolioData.isEmpty {
                Divider()

                VStack(spacing: 0) {
                    ForEach(Array(portfolioData.enumerated()), id: \.element.account.id) { index, item in
                        accountRow(item: item)
                            .padding(.vertical, 10)

                        if index < portfolioData.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }

    // MARK: - Account row

    private func accountRow(item: (account: Account, balance: Decimal)) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(hex: item.account.color))
                .frame(width: 8, height: 8)

            Text(item.account.icon)
                .font(.title3)

            Text(item.account.name)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()

            // Balance with sign and color
            Text(formattedBalance(item.balance))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(item.balance < 0 ? Color.expense : .primary)

            // Percentage of total positive assets
            if totalPositive > 0 {
                let pct = Double(truncating: (item.balance / totalPositive * 100) as NSDecimalNumber)
                Text(item.balance >= 0 ? "\(Int(pct))%" : "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

    // MARK: - Formatting

    private var formattedTotal: String {
        let cm = appViewModel.currencyManager
        let converted = cm.convert(abs(totalBalance))
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let formatted = formatter.string(from: converted as NSDecimalNumber) ?? "0"
        let sign = totalBalance < 0 ? "-" : ""
        return "\(sign)\(formatted) \(cm.selectedCurrency.symbol)"
    }

    private func formattedBalance(_ balance: Decimal) -> String {
        let cm = appViewModel.currencyManager
        if balance < 0 {
            return "-\(cm.formatAmount(abs(balance)))"
        }
        return cm.formatAmount(balance)
    }
}
