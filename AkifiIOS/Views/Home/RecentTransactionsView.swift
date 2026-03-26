import SwiftUI

struct RecentTransactionsView: View {
    let transactions: [Transaction]
    let categories: [Category]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Последние операции")
                    .font(.headline)
                Spacer()
                Text("Все")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }

            if transactions.isEmpty {
                ContentUnavailableView(
                    "Нет операций",
                    systemImage: "tray",
                    description: Text("Добавьте первую операцию")
                )
                .frame(height: 120)
            } else {
                ForEach(transactions.prefix(5)) { transaction in
                    TransactionRowView(
                        transaction: transaction,
                        category: categories.first { $0.id == transaction.categoryId }
                    )
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}
