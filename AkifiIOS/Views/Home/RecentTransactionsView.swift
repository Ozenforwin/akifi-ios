import SwiftUI

struct RecentTransactionsView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let transactions: [Transaction]
    let categories: [Category]
    var onEdit: ((Transaction) -> Void)?
    var onDelete: ((Transaction) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Последние операции")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            if transactions.isEmpty {
                ContentUnavailableView(
                    "Нет операций",
                    systemImage: "tray",
                    description: Text("Добавьте первую операцию")
                )
                .frame(height: 120)
            } else {
                List {
                    ForEach(transactions.prefix(10)) { transaction in
                        TransactionRowView(
                            transaction: transaction,
                            category: categories.first { $0.id == transaction.categoryId }
                        )
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onEdit?(transaction)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                onDelete?(transaction)
                            } label: {
                                Label("Удалить", systemImage: "trash.fill")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                onEdit?(transaction)
                            } label: {
                                Label("Изменить", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollDisabled(true)
                .frame(height: CGFloat(min(transactions.count, 10)) * 88)
            }
        }
    }
}
