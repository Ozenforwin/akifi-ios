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
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(account.name), баланс \(appViewModel.currencyManager.formatAmount(balance.displayAmount))")
    }
}
