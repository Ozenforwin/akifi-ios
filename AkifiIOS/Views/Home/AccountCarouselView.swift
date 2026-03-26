import SwiftUI

struct AccountCarouselView: View {
    let accounts: [Account]
    @Binding var selectedIndex: Int
    let balanceFor: (Account) -> Int64

    var body: some View {
        TabView(selection: $selectedIndex) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                AccountCardView(account: account, balance: balanceFor(account))
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .frame(height: 180)
    }
}

struct AccountCardView: View {
    let account: Account
    let balance: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(account.icon)
                    .font(.title2)
                Text(account.name)
                    .font(.headline)
                Spacer()
            }

            Spacer()

            Text(formatBalance(balance))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(balance < 0 ? .red : .primary)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
        .padding(.horizontal, 4)
    }

    private func formatBalance(_ amount: Int64) -> String {
        let value = Double(amount) / 100.0
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }
}
