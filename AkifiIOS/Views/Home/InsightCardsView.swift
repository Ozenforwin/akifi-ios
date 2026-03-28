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
        let fmt = appViewModel.currencyManager

        let now = Date()
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let prevMonthStart = calendar.date(byAdding: .month, value: -1, to: monthStart)!

        // Also compute weekly data
        let weekStart = calendar.date(byAdding: .day, value: -7, to: now)!
        let prevWeekStart = calendar.date(byAdding: .day, value: -14, to: now)!

        var thisMonthExp: Int64 = 0
        var prevMonthExp: Int64 = 0
        var thisWeekExp: Int64 = 0
        var prevWeekExp: Int64 = 0
        var thisMonthCount = 0
        var biggestAmount: Int64 = 0
        var biggestCatId: String?
        var catSpending: [String: Int64] = [:]

        for tx in transactions {
            guard tx.type == .expense, !tx.isTransfer else { continue }
            guard let d = df.date(from: tx.date) else { continue }

            if d >= monthStart {
                thisMonthExp += tx.amount
                thisMonthCount += 1
                if tx.amount > biggestAmount {
                    biggestAmount = tx.amount
                    biggestCatId = tx.categoryId
                }
                if let catId = tx.categoryId {
                    catSpending[catId, default: 0] += tx.amount
                }
            } else if d >= prevMonthStart {
                prevMonthExp += tx.amount
            }

            if d >= weekStart {
                thisWeekExp += tx.amount
            } else if d >= prevWeekStart {
                prevWeekExp += tx.amount
            }
        }

        // 1. Weekly trend
        if prevWeekExp > 0 && thisWeekExp > 0 {
            let change = Double(thisWeekExp - prevWeekExp) / Double(prevWeekExp) * 100
            if change > 15 {
                result.append(Insight(
                    emoji: "📈",
                    title: "Расходы растут",
                    subtitle: "На этой неделе потрачено на \(Int(change))% больше, чем на прошлой",
                    color: Color.warning
                ))
            } else if change < -15 {
                result.append(Insight(
                    emoji: "📉",
                    title: "Расходы снижаются",
                    subtitle: "На этой неделе потрачено на \(Int(abs(change)))% меньше — так держать!",
                    color: Color.income
                ))
            }
        }

        // 2. Monthly comparison
        if prevMonthExp > 0 && thisMonthExp > 0 {
            let change = Double(thisMonthExp - prevMonthExp) / Double(prevMonthExp) * 100
            if change > 20 {
                let thisFormatted = fmt.formatAmount(thisMonthExp.displayAmount)
                let prevFormatted = fmt.formatAmount(prevMonthExp.displayAmount)
                result.append(Insight(
                    emoji: "⚡️",
                    title: "Месяц дороже прошлого",
                    subtitle: "Уже \(thisFormatted) против \(prevFormatted) за прошлый месяц",
                    color: Color.expense
                ))
            }
        }

        // 3. Big single expense
        if thisMonthCount >= 3 && biggestAmount > 0 {
            let avg = thisMonthExp / Int64(thisMonthCount)
            if biggestAmount > avg * 3 {
                let catName = biggestCatId.flatMap { id in dataStore.categories.first { $0.id == id }?.name } ?? "Прочее"
                let pct = thisMonthExp > 0 ? Int(Double(biggestAmount) / Double(thisMonthExp) * 100) : 0
                result.append(Insight(
                    emoji: "💸",
                    title: "Крупная трата: \(catName)",
                    subtitle: "Одна операция — \(pct)% месячных расходов",
                    color: Color.expense
                ))
            }
        }

        // 4. Top category eating budget
        if let topCat = catSpending.max(by: { $0.value < $1.value }),
           thisMonthExp > 0 {
            let pct = Int(Double(topCat.value) / Double(thisMonthExp) * 100)
            if pct >= 40 {
                let catName = dataStore.categories.first { $0.id == topCat.key }?.name ?? "Категория"
                let catIcon = dataStore.categories.first { $0.id == topCat.key }?.icon ?? "📦"
                result.append(Insight(
                    emoji: catIcon,
                    title: "\(catName) — \(pct)% расходов",
                    subtitle: "Эта категория съедает почти половину бюджета",
                    color: Color.warning
                ))
            }
        }

        // 5. No transactions warning
        let noTxDays = daysSinceLastTransaction(transactions: transactions, df: df)
        if noTxDays >= 3 {
            result.append(Insight(
                emoji: "😴",
                title: "Тишина уже \(noTxDays) дн.",
                subtitle: "Вы давно не записывали операции — не забывайте вести учёт",
                color: Color.warning
            ))
        }

        return result
    }

    var body: some View {
        if !insights.isEmpty {
            VStack(spacing: 8) {
                ForEach(insights) { insight in
                    HStack(spacing: 12) {
                        Text(insight.emoji)
                            .font(.title2)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(insight.title)
                                    .font(.subheadline.weight(.semibold))
                                Image(systemName: "sparkles")
                                    .font(.caption2)
                                    .foregroundStyle(insight.color.opacity(0.6))
                            }
                            Text(insight.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(insight.color.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [insight.color.opacity(0.4), insight.color.opacity(0.15)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
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
    let emoji: String
    let title: String
    let subtitle: String
    let color: Color
}
