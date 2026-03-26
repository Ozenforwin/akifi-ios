import SwiftUI

struct TransactionRowView: View {
    let transaction: Transaction
    let category: Category?

    var body: some View {
        HStack(spacing: 12) {
            // Category icon
            Text(category?.icon ?? "💰")
                .font(.title2)
                .frame(width: 40, height: 40)
                .background(Color(hex: category?.color ?? "#60A5FA").opacity(0.15))
                .clipShape(Circle())

            // Description
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.description ?? category?.name ?? "Операция")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Text(transaction.date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Amount
            Text(formattedAmount)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(transaction.type == .income ? .green : .primary)
        }
        .padding(.vertical, 4)
    }

    private var formattedAmount: String {
        let value = Double(transaction.amount) / 100.0
        let sign = transaction.type == .income ? "+" : "-"
        return "\(sign)$\(String(format: "%.2f", value))"
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
