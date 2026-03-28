import SwiftUI
import Charts

struct CategoryBreakdownView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let data: [CategorySpending]
    var transactions: [Transaction] = []

    @State private var isExpanded = false
    @State private var selectedCategory: CategorySpending?

    private let collapsedCount = 5

    private var visibleData: [CategorySpending] {
        if isExpanded || data.count <= collapsedCount + 1 {
            return data
        }
        return Array(data.prefix(collapsedCount))
    }

    private var hasMore: Bool {
        data.count > collapsedCount + 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("По категориям")
                .font(.headline)

            if data.isEmpty {
                ContentUnavailableView("Нет расходов", systemImage: "chart.pie")
                    .frame(height: 200)
            } else {
                // Donut chart
                Chart(data) { item in
                    SectorMark(
                        angle: .value("Сумма", item.amount),
                        innerRadius: .ratio(0.5),
                        angularInset: 1.5
                    )
                    .foregroundStyle(Color(hex: item.color))
                    .cornerRadius(4)
                    .opacity(selectedCategory == nil || selectedCategory?.id == item.id ? 1.0 : 0.4)
                }
                .frame(height: 200)

                // Category list
                VStack(spacing: 0) {
                    ForEach(visibleData) { item in
                        Button {
                            selectedCategory = item
                        } label: {
                            categoryRow(item)
                        }
                        .buttonStyle(.plain)
                    }

                    // Show more / less
                    if hasMore {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            HStack {
                                Spacer()
                                Text(isExpanded ? "Свернуть" : "Ещё \(data.count - collapsedCount) категорий")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Color.accent)
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(Color.accent)
                                Spacer()
                            }
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(.systemGray4).opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
        .sheet(item: $selectedCategory) { category in
            CategoryTransactionsSheet(
                category: category,
                transactions: transactions.filter {
                    $0.type == .expense && !$0.isTransfer && $0.categoryId == category.id
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func categoryRow(_ item: CategorySpending) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: item.color))
                .frame(width: 10, height: 10)
            Text(item.icon)
                .font(.caption)
            Text(item.name)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
            Text(appViewModel.currencyManager.formatAmount(item.amount))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            Text("\(Int(item.percentage))%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Category Transactions Sheet

struct CategoryTransactionsSheet: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Environment(\.dismiss) private var dismiss

    let category: CategorySpending
    let transactions: [Transaction]

    var body: some View {
        NavigationStack {
            Group {
                if transactions.isEmpty {
                    ContentUnavailableView("Нет операций", systemImage: "tray")
                } else {
                    List {
                        // Summary
                        Section {
                            HStack {
                                Text(category.icon)
                                    .font(.title2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(category.name)
                                        .font(.headline)
                                    Text("\(transactions.count) операций")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(appViewModel.currencyManager.formatAmount(category.amount))
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(Color.expense)
                            }
                        }

                        // Transactions
                        Section {
                            ForEach(transactions) { tx in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tx.description ?? category.name)
                                            .font(.subheadline)
                                        Text(tx.date)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("-\(appViewModel.currencyManager.formatAmount(tx.amount.displayAmount))")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.expense)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(category.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }
}

extension CategorySpending: Equatable {
    static func == (lhs: CategorySpending, rhs: CategorySpending) -> Bool {
        lhs.id == rhs.id
    }
}
