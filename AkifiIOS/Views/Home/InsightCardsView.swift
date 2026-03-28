import SwiftUI

struct InsightCardsView: View {
    @Environment(AppViewModel.self) private var appViewModel

    private var dataStore: DataStore { appViewModel.dataStore }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private var insights: [Insight] {
        var result: [Insight] = []
        let transactions = dataStore.transactions
        let calendar = Calendar.current
        let df = Self.dateFormatter

        let now = Date()
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let prevMonthStart = calendar.date(byAdding: .month, value: -1, to: monthStart)!

        var thisTotal: Int64 = 0
        var prevTotal: Int64 = 0
        var thisMonthCount = 0
        var biggestThisMonth: Int64 = 0

        for tx in transactions {
            guard tx.type == .expense, let d = df.date(from: tx.date) else { continue }
            if d >= monthStart {
                thisTotal += tx.amount
                thisMonthCount += 1
                if tx.amount > biggestThisMonth { biggestThisMonth = tx.amount }
            } else if d >= prevMonthStart {
                prevTotal += tx.amount
            }
        }

        if prevTotal > 0 && thisTotal > 0 {
            let change = Double(thisTotal - prevTotal) / Double(prevTotal) * 100
            if abs(change) > 10 {
                let icon = change > 0 ? "arrow.up.right" : "arrow.down.right"
                let color: Color = change > 0 ? Color.expense : Color.income
                let label = change > 0 ? "Расходы выросли на \(Int(abs(change)))%" : "Расходы снизились на \(Int(abs(change)))%"
                result.append(Insight(icon: icon, color: color, text: label))
            }
        }

        let noTxDays = daysSinceLastTransaction(transactions: transactions, df: df)
        if noTxDays >= 3 {
            result.append(Insight(icon: "clock.badge.exclamationmark", color: Color.warning, text: "Нет операций уже \(noTxDays) дн."))
        }

        if thisMonthCount >= 5 {
            let avg = thisTotal / Int64(thisMonthCount)
            if biggestThisMonth > avg * 3 {
                let formatted = appViewModel.currencyManager.formatAmount(biggestThisMonth.displayAmount)
                result.append(Insight(icon: "exclamationmark.triangle", color: Color.expense, text: "Крупный расход: \(formatted)"))
            }
        }

        return result
    }

    var body: some View {
        if !insights.isEmpty {
            VStack(spacing: 8) {
                ForEach(insights) { insight in
                    HStack(spacing: 12) {
                        Image(systemName: insight.icon)
                            .font(.system(size: 16))
                            .foregroundStyle(insight.color)

                        Text(insight.text)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(insight.color.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    private func daysSinceLastTransaction(transactions: [Transaction], df: DateFormatter) -> Int {
        guard let latest = transactions.compactMap({ df.date(from: $0.date) }).max() else { return 0 }
        return Calendar.current.dateComponents([.day], from: latest, to: Date()).day ?? 0
    }
}

struct Insight: Identifiable {
    let id = UUID()
    let icon: String
    let color: Color
    let text: String
}
