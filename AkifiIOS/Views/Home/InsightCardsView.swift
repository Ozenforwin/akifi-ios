import SwiftUI

struct InsightCardsView: View {
    @Environment(AppViewModel.self) private var appViewModel

    private var dataStore: DataStore { appViewModel.dataStore }

    private var insights: [Insight] {
        var result: [Insight] = []
        let transactions = dataStore.transactions
        let calendar = Calendar.current
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        let now = Date()
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let prevMonthStart = calendar.date(byAdding: .month, value: -1, to: monthStart)!

        let thisMonth = transactions.filter {
            guard let d = df.date(from: $0.date) else { return false }
            return d >= monthStart && $0.type == .expense
        }
        let prevMonth = transactions.filter {
            guard let d = df.date(from: $0.date) else { return false }
            return d >= prevMonthStart && d < monthStart && $0.type == .expense
        }

        let thisTotal = thisMonth.reduce(Int64(0)) { $0 + $1.amount }
        let prevTotal = prevMonth.reduce(Int64(0)) { $0 + $1.amount }

        if prevTotal > 0 && thisTotal > 0 {
            let change = Double(thisTotal - prevTotal) / Double(prevTotal) * 100
            if abs(change) > 10 {
                let icon = change > 0 ? "arrow.up.right" : "arrow.down.right"
                let color: Color = change > 0 ? .red : .green
                let label = change > 0 ? "Расходы выросли на \(Int(abs(change)))%" : "Расходы снизились на \(Int(abs(change)))%"
                result.append(Insight(icon: icon, color: color, text: label))
            }
        }

        let noTxDays = daysSinceLastTransaction(transactions: transactions, df: df)
        if noTxDays >= 3 {
            result.append(Insight(icon: "clock.badge.exclamationmark", color: .orange, text: "Нет операций уже \(noTxDays) дн."))
        }

        if thisMonth.count >= 5 {
            let avg = thisTotal / Int64(thisMonth.count)
            if let biggest = thisMonth.max(by: { $0.amount < $1.amount }), biggest.amount > avg * 3 {
                let formatted = appViewModel.currencyManager.formatAmount(biggest.amount.displayAmount)
                result.append(Insight(icon: "exclamationmark.triangle", color: .red, text: "Крупный расход: \(formatted)"))
            }
        }

        return result
    }

    var body: some View {
        if !insights.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Инсайты")
                    .font(.headline)

                ForEach(insights) { insight in
                    HStack(spacing: 10) {
                        Image(systemName: insight.icon)
                            .foregroundStyle(insight.color)
                            .frame(width: 24)
                        Text(insight.text)
                            .font(.subheadline)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
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
