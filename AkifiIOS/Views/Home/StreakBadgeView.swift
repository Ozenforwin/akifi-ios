import SwiftUI

struct StreakBadgeView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var currentStreak = 0

    private var dataStore: DataStore { appViewModel.dataStore }

    private var streakGradient: LinearGradient {
        let colors: [Color] = if currentStreak >= 30 {
            [Color(hex: "#8B5CF6"), Color(hex: "#D946EF")]
        } else if currentStreak >= 14 {
            [Color(hex: "#F97316"), Color(hex: "#EF4444")]
        } else if currentStreak >= 7 {
            [Color(hex: "#FBBF24"), Color(hex: "#F97316")]
        } else if currentStreak >= 3 {
            [Color(hex: "#FDE68A"), Color(hex: "#FBBF24")]
        } else {
            [Color.gray, Color.gray.opacity(0.7)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        Group {
            if currentStreak > 0 {
                HStack(spacing: 10) {
                    // Flame icon in gradient square
                    Image(systemName: "flame.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(streakGradient)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(currentStreak) \(streakLabel)")
                            .font(.subheadline.weight(.semibold))
                        Text(String(localized: "streak.consecutiveDays"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 2) {
                        Image(systemName: "flame.fill")
                            .foregroundStyle(streakGradient)
                        Text("\(currentStreak)")
                    }
                    .font(.system(size: 18, weight: .bold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .task { calculateStreak() }
        .onChange(of: dataStore.transactions.count) { calculateStreak() }
    }

    private var streakLabel: String {
        let mod10 = currentStreak % 10
        let mod100 = currentStreak % 100
        if mod100 >= 11 && mod100 <= 19 { return String(localized: "streak.days.many") }
        if mod10 == 1 { return String(localized: "streak.days.one") }
        if mod10 >= 2 && mod10 <= 4 { return String(localized: "streak.days.few") }
        return String(localized: "streak.days.many")
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private func calculateStreak() {
        let df = Self.dateFormatter
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
