import SwiftUI

struct TransactionRowView: View {
    @Environment(AppViewModel.self) private var appViewModel
    let transaction: Transaction
    let category: Category?

    var body: some View {
        HStack(spacing: 12) {
            Text(category?.icon ?? "💰")
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(Color(hex: category?.color ?? "#60A5FA").opacity(0.15))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.description ?? category?.name ?? "Операция")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Text(transaction.date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(formattedAmount)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(amountColor)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var amountColor: Color {
        switch transaction.type {
        case .income: return .green
        case .expense: return .red
        case .transfer: return .blue
        }
    }

    private var formattedAmount: String {
        let sign: String = switch transaction.type {
        case .income: "+"
        case .expense: "-"
        case .transfer: "↔ "
        }
        let formatted = appViewModel.currencyManager.formatAmount(transaction.amount.displayAmount)
        return "\(sign)\(formatted)"
    }
}
