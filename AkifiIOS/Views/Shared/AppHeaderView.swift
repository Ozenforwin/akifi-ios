import SwiftUI

struct AppHeaderView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @Binding var showProfile: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button {
                showProfile = true
            } label: {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .stroke(
                                appViewModel.paymentManager.isPremium
                                    ? Color.tierGold
                                    : Color.gray.opacity(0.3),
                                lineWidth: 2
                            )
                            .frame(width: 36, height: 36)

                        if let avatarUrl = appViewModel.dataStore.profile?.avatarUrl,
                           let url = URL(string: avatarUrl) {
                            CachedAsyncImage(url: url) {
                                Image(systemName: "person.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 32, height: 32)
                            .clipShape(Circle())
                        } else {
                            Image(systemName: "person.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        Text(displayName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    if appViewModel.paymentManager.isPremium {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.tierGold)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // Currency picker as popup menu (like account switcher)
            Menu {
                ForEach(CurrencyCode.allCases, id: \.self) { currency in
                    Button {
                        appViewModel.currencyManager.selectedCurrency = currency
                    } label: {
                        HStack {
                            Text("\(currency.symbol) \(currency.name)")
                            if appViewModel.currencyManager.selectedCurrency == currency {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text(appViewModel.currencyManager.selectedCurrency.symbol)
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var displayName: String {
        if let name = appViewModel.dataStore.profile?.fullName, !name.isEmpty {
            return name
        }
        let email = appViewModel.authManager.currentUser?.email ?? ""
        return email.components(separatedBy: "@").first ?? "User"
    }
}
