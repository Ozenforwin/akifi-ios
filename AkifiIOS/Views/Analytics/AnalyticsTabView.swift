import SwiftUI

struct AnalyticsTabView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Аналитика",
                systemImage: "chart.bar.fill",
                description: Text("Графики и отчеты появятся в следующем обновлении")
            )
            .navigationTitle("Аналитика")
        }
    }
}
