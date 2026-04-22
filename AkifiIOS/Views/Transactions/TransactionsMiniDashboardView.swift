import SwiftUI
import Charts

struct TransactionsMiniDashboardView: View {
    let transactions: [Transaction]
    var onOpenReports: () -> Void

    @Environment(AppViewModel.self) private var appVM

    private var monthlyData: [MonthEntry] {
        let cal = Calendar.current
        let now = Date()
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        let months: [(date: Date, key: String)] = (0..<6).reversed().compactMap { offset in
            guard let d = cal.date(byAdding: .month, value: -offset, to: now) else { return nil }
            let comps = cal.dateComponents([.year, .month], from: d)
            return (d, "\(comps.year!)-\(String(format: "%02d", comps.month!))")
        }

        let shortLabels: [Int: String] = [
            1: String(localized: "month.jan"), 2: String(localized: "month.feb"), 3: String(localized: "month.mar"), 4: String(localized: "month.apr"),
            5: String(localized: "month.may"), 6: String(localized: "month.jun"), 7: String(localized: "month.jul"), 8: String(localized: "month.aug"),
            9: String(localized: "month.sep"), 10: String(localized: "month.oct"), 11: String(localized: "month.nov"), 12: String(localized: "month.dec")
        ]

        let currentKey: String = {
            let c = cal.dateComponents([.year, .month], from: now)
            return "\(c.year!)-\(String(format: "%02d", c.month!))"
        }()

        let dataStore = appVM.dataStore
        return months.map { item in
            let filtered = transactions.filter { tx in
                !tx.isTransfer && tx.date.hasPrefix(item.key)
            }
            // ADR-001: FX-normalize to base currency before summing so
            // VND/USD rows on their own accounts don't get read as rubles.
            let inc = filtered.filter { $0.type == .income }.reduce(Int64(0)) { $0 + dataStore.amountInBase($1) }
            let exp = filtered.filter { $0.type == .expense }.reduce(Int64(0)) { $0 + dataStore.amountInBase($1) }
            let month = cal.component(.month, from: item.date)
            return MonthEntry(
                label: shortLabels[month] ?? "",
                income: Double(inc) / 100,
                expense: Double(exp) / 100,
                isCurrent: item.key == currentKey
            )
        }
    }

    private var maxValue: Double {
        let vals = monthlyData.flatMap { [$0.income, $0.expense] }
        return max(vals.max() ?? 1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart(monthlyData) { entry in
                BarMark(
                    x: .value(String(localized: "chart.month"), entry.label),
                    y: .value(String(localized: "chart.amount"), entry.income)
                )
                .foregroundStyle(Color.income)
                .position(by: .value(String(localized: "chart.type"), "income"))

                BarMark(
                    x: .value(String(localized: "chart.month"), entry.label),
                    y: .value(String(localized: "chart.amount"), entry.expense)
                )
                .foregroundStyle(Color.expense)
                .position(by: .value(String(localized: "chart.type"), "expense"))
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(abbreviate(v))
                                .font(.caption2)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            let isCurrent = monthlyData.first(where: { $0.label == label })?.isCurrent == true
                            Text(label)
                                .font(.caption2)
                                .fontWeight(isCurrent ? .bold : .regular)
                                .foregroundStyle(isCurrent ? .primary : .secondary)
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .frame(height: 120)

            Button(action: onOpenReports) {
                Text(String(localized: "dashboard.expenseOverview"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.accent)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func abbreviate(_ value: Double) -> String {
        if value >= 1_000_000 { return "\(Int(value / 1_000_000))M" }
        if value >= 1_000 { return "\(Int(value / 1_000))k" }
        return "\(Int(value))"
    }
}

private struct MonthEntry: Identifiable {
    let id = UUID()
    let label: String
    let income: Double
    let expense: Double
    let isCurrent: Bool
}
