import SwiftUI

struct BudgetsTabView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Бюджеты",
                systemImage: "wallet.bifold.fill",
                description: Text("Управление бюджетами появится в следующем обновлении")
            )
            .navigationTitle("Бюджеты")
        }
    }
}
