import SwiftUI

struct StreakBadgeView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @State private var currentStreak = 0

    private var dataStore: DataStore { appViewModel.dataStore }

    @ScaledMetric(relativeTo: .body) private var iconTileSize: CGFloat = 36

    /// The flame's colour climbs with the streak — the tier is the meaning
    /// (one solid colour per tier; the old two-stop gradients were
    /// decoration).
    nonisolated static func tierColorHex(for streak: Int) -> String? {
        switch streak {
        case 30...: "#8B5CF6"
        case 14...: "#F97316"
        case 7...: "#F59E0B"
        case 3...: "#FBBF24"
        default: nil
        }
    }

    private var tierColor: Color {
        Self.tierColorHex(for: currentStreak).map { Color(hex: $0) } ?? .gray
    }

    var body: some View {
        Group {
            if currentStreak > 0 {
                HStack(spacing: 12) {
                    Image(systemName: "flame.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tierColor)
                        .frame(width: iconTileSize, height: iconTileSize)
                        .background(tierColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(currentStreak) \(streakLabel)")
                            .font(.subheadline.weight(.semibold))
                        Text(String(localized: "streak.consecutiveDays"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    Text(verbatim: "\(currentStreak)")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(tierColor)
                        .accessibilityHidden(true)
                }
                .akifiCard()
                .accessibilityElement(children: .combine)
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

    private static var dateFormatter: DateFormatter { AppDateFormatters.isoDate }

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
