import SwiftUI
import Charts

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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Портфель")
                    .font(.headline)
                Spacer()
                Text(appViewModel.currencyManager.formatAmount(totalBalance))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if portfolioData.isEmpty {
                ContentUnavailableView("Нет счетов", systemImage: "creditcard")
                    .frame(height: 150)
            } else {
                Chart(portfolioData, id: \.account.id) { item in
                    BarMark(
                        x: .value("Баланс", item.balance),
                        y: .value("Счёт", "\(item.account.icon) \(item.account.name)")
                    )
                    .foregroundStyle(Color(hex: item.account.color).gradient)
                    .cornerRadius(6)
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(portfolioData.count * 44 + 20))

                ForEach(portfolioData, id: \.account.id) { item in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(hex: item.account.color))
                            .frame(width: 10, height: 10)
                        Text("\(item.account.icon) \(item.account.name)")
                            .font(.caption)
                        Spacer()
                        Text(appViewModel.currencyManager.formatAmount(item.balance))
                            .font(.caption.weight(.medium))
                        if totalBalance > 0 {
                            let pct = Double(truncating: (item.balance / totalBalance * 100) as NSDecimalNumber)
                            Text("\(Int(pct))%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 32, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}
