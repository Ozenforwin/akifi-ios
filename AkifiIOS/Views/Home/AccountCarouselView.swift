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
    @Environment(AppViewModel.self) private var appViewModel
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

            Text(appViewModel.currencyManager.formatAmount(balance.displayAmount))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(balance < 0 ? .red : .primary)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(hex: account.color).opacity(0.3),
                    Color(hex: account.color).opacity(0.55)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: Color(hex: account.color).opacity(0.2), radius: 8, x: 0, y: 4)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(account.name), баланс \(appViewModel.currencyManager.formatAmount(balance.displayAmount))")
    }
}
