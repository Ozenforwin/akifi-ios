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
                    .foregroundStyle(Color.accent)
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
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
    }
}
