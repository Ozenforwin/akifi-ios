import SwiftUI

struct StreakBadgeView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var currentStreak = 0

    private var dataStore: DataStore { appViewModel.dataStore }

    var body: some View {
        Group {
            if currentStreak > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(.orange.gradient)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(currentStreak) \(streakLabel)")
                            .font(.subheadline.weight(.semibold))
                        Text("подряд с операциями")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(.systemBackground))
                .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Стрик \(currentStreak) дней")
            }
        }
        .task { calculateStreak() }
        .onChange(of: dataStore.transactions.count) { calculateStreak() }
    }

    private var streakLabel: String {
        let mod10 = currentStreak % 10
        let mod100 = currentStreak % 100
        if mod100 >= 11 && mod100 <= 19 { return "дней" }
        if mod10 == 1 { return "день" }
        if mod10 >= 2 && mod10 <= 4 { return "дня" }
        return "дней"
    }

    private func calculateStreak() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let uniqueDates = Set(dataStore.transactions.compactMap { df.date(from: $0.date) }.map { calendar.startOfDay(for: $0) })

        var streak = 0
        var checkDate = today

        while uniqueDates.contains(checkDate) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: checkDate) else { break }
            checkDate = prev
        }

        currentStreak = streak
    }
}
