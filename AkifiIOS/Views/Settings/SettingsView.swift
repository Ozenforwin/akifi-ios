import SwiftUI

struct SettingsView: View {
    @Environment(AppViewModel.self) private var appViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("Профиль") {
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .font(.title)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading) {
                            Text(appViewModel.authManager.currentUser?.email ?? "Пользователь")
                                .font(.headline)
                        }
                    }
                }

                Section("Приложение") {
                    NavigationLink {
                        CurrencyPickerView()
                    } label: {
                        Label("Валюта", systemImage: "dollarsign.circle")
                    }

                    NavigationLink {
                        Text("Категории")
                    } label: {
                        Label("Категории", systemImage: "tag")
                    }

                    NavigationLink {
                        Text("Уведомления")
                    } label: {
                        Label("Уведомления", systemImage: "bell")
                    }
                }

                Section("Premium") {
                    NavigationLink {
                        Text("Premium")
                    } label: {
                        Label("Akifi Pro", systemImage: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        Task {
                            try? await appViewModel.authManager.signOut()
                        }
                    } label: {
                        Label("Выйти", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("Настройки")
        }
    }
}

struct CurrencyPickerView: View {
    @Environment(AppViewModel.self) private var appViewModel

    var body: some View {
        List {
            ForEach(CurrencyCode.allCases, id: \.self) { currency in
                Button {
                    appViewModel.currencyManager.selectedCurrency = currency
                } label: {
                    HStack {
                        Text(currency.symbol)
                            .font(.title2)
                        VStack(alignment: .leading) {
                            Text(currency.rawValue)
                                .font(.headline)
                            Text(currency.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if appViewModel.currencyManager.selectedCurrency == currency {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.green)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .navigationTitle("Валюта")
    }
}
