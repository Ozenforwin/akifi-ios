import SwiftUI

struct RecentTransactionsView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let transactions: [Transaction]
    let categories: [Category]
    var onEdit: ((Transaction) -> Void)?
    var onDelete: ((Transaction) -> Void)?

    /// Rendered height of every row, by transaction id. The list sits inside
    /// Home's scroll view with its own scrolling off, so it needs an explicit
    /// height; measuring the rows (instead of a fixed 88 pt per row) keeps
    /// the last rows from being cut off at large Dynamic Type sizes.
    @State private var rowHeights: [String: CGFloat] = [:]

    nonisolated static let maxRows = 10
    /// Vertical inset above and below each row inside the list.
    nonisolated static let rowVerticalInset: CGFloat = 4
    /// Height assumed for a row until it has been measured.
    nonisolated static let estimatedRowHeight: CGFloat = 80

    /// Height of a non-scrolling list showing `rowIds`: each row's measured
    /// height (the estimate until measured) plus its insets.
    nonisolated static func listHeight(
        rowIds: [String],
        measured: [String: CGFloat],
        estimate: CGFloat = estimatedRowHeight,
        verticalInset: CGFloat = rowVerticalInset
    ) -> CGFloat {
        rowIds.reduce(0) { total, id in
            total + (measured[id] ?? estimate) + 2 * verticalInset
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "home.recentTransactions"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if transactions.isEmpty {
                ContentUnavailableView(
                    String(localized: "home.noTransactions"),
                    systemImage: "tray",
                    description: Text(String(localized: "home.addFirstTransaction"))
                )
                .frame(maxWidth: .infinity)
                .akifiCard()
            } else {
                let rows = Array(transactions.prefix(Self.maxRows))
                List {
                    ForEach(rows) { transaction in
                        TransactionRowView(
                            transaction: transaction,
                            category: categories.first { $0.id == transaction.categoryId }
                        )
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            if rowHeights[transaction.id] != height { rowHeights[transaction.id] = height }
                        }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: Self.rowVerticalInset, leading: 0, bottom: Self.rowVerticalInset, trailing: 0))
                        .listRowBackground(Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onEdit?(transaction)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                onDelete?(transaction)
                            } label: {
                                Label(String(localized: "common.delete"), systemImage: "trash.fill")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                onEdit?(transaction)
                            } label: {
                                Label(String(localized: "common.edit"), systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(height: Self.listHeight(rowIds: rows.map(\.id), measured: rowHeights))
            }
        }
    }
}
