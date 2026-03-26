import SwiftUI
import Charts

struct CategoryBreakdownView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let data: [CategorySpending]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("По категориям")
                .font(.headline)

            if data.isEmpty {
                ContentUnavailableView("Нет расходов", systemImage: "chart.pie")
                    .frame(height: 200)
            } else {
                Chart(data) { item in
                    SectorMark(
                        angle: .value("Сумма", item.amount),
                        innerRadius: .ratio(0.5),
                        angularInset: 1.5
                    )
                    .foregroundStyle(Color(hex: item.color))
                    .cornerRadius(4)
                }
                .frame(height: 200)

                // Legend
                LazyVStack(spacing: 8) {
                    ForEach(data) { item in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color(hex: item.color))
                                .frame(width: 10, height: 10)
                            Text(item.icon)
                                .font(.caption)
                            Text(item.name)
                                .font(.subheadline)
                            Spacer()
                            Text(appViewModel.currencyManager.formatAmount(item.amount))
                                .font(.subheadline.weight(.medium))
                            Text("\(Int(item.percentage))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}
