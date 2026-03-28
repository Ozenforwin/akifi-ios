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

            // Total balance
            Text(appViewModel.currencyManager.formatAmount(totalBalance))
                .font(.system(size: 28, weight: .bold, design: .rounded))

            // Stacked progress bar
            if totalBalance > 0 {
                GeometryReader { geo in
                    HStack(spacing: 1.5) {
                        ForEach(portfolioData, id: \.account.id) { item in
                            let pct = item.balance > 0
                                ? CGFloat(truncating: (item.balance / totalBalance) as NSDecimalNumber)
                                : 0
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(hex: item.account.color).gradient)
                                .frame(width: max(4, geo.size.width * pct))
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
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color(hex: item.account.color))
                                .frame(width: 8, height: 8)

                            Text(item.account.icon)
                                .font(.title3)

                            Text(item.account.name)
                                .font(.subheadline)

                            Spacer()

                            Text(appViewModel.currencyManager.formatAmount(item.balance))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()

                            if totalBalance > 0 {
                                let pct = Double(truncating: (item.balance / totalBalance * 100) as NSDecimalNumber)
                                Text("\(Int(pct))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, alignment: .trailing)
                            }
                        }
                        .padding(.vertical, 10)

                        if index < portfolioData.count - 1 {
                            Divider()
                        }
                    }
                }
            } else {
                ContentUnavailableView(String(localized: "analytics.noAccounts"), systemImage: "creditcard")
                    .frame(height: 100)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(.systemGray4).opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }
}
