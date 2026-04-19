import SwiftUI
import WidgetKit

/// Streak widget. Ships two flavours in the same `Widget` config:
///   * `.systemSmall` — home-screen square with flame, day count, ring.
///   * `.accessoryCircular` — lock-screen small complication.
///
/// Progress ring fills `currentStreak / nextMilestone`. Once the user hits
/// the top milestone (365), the ring is full and subtitle says "Max".
struct StreakWidgetView: View {
    let entry: SnapshotEntry
    let family: WidgetFamily

    private var progress: Double {
        guard entry.snapshot.nextMilestone > 0 else { return 1.0 }
        return min(1.0, Double(entry.snapshot.currentStreak) / Double(entry.snapshot.nextMilestone))
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            lockScreenView
        default:
            homeView
        }
    }

    // MARK: - Home screen (small)

    private var homeView: some View {
        ZStack {
            LinearGradient(
                colors: [Color.orange.opacity(0.18), Color.red.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 6) {
                HStack {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.orange)
                    Spacer()
                    Text(LocalizedStringResource("widget.streak.title", defaultValue: "Стрик"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                ZStack {
                    Circle()
                        .stroke(Color.orange.opacity(0.18), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            LinearGradient(colors: [.orange, .red],
                                           startPoint: .topLeading,
                                           endPoint: .bottomTrailing),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(WidgetFormatters.streakCount(entry.snapshot.currentStreak))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .minimumScaleFactor(0.5)
                            .foregroundStyle(.primary)
                        Text(LocalizedStringResource("widget.streak.daysShort", defaultValue: "дн."))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 74, height: 74)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    LocalizedStringResource("widget.streak.title", defaultValue: "Стрик")
                )
                .accessibilityValue(
                    String(format: String(
                        localized: "widget.streak.valueA11y",
                        defaultValue: "%d дней, следующая веха %d"
                    ), entry.snapshot.currentStreak, entry.snapshot.nextMilestone)
                )

                Text(String(
                    format: String(
                        localized: "widget.streak.nextMilestone",
                        defaultValue: "До %d"
                    ),
                    entry.snapshot.nextMilestone
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .widgetURL(URL(string: "akifi://home"))
    }

    // MARK: - Lock screen (circular)

    @ViewBuilder
    private var lockScreenView: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(WidgetFormatters.streakCount(entry.snapshot.currentStreak))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
            }
        }
        .widgetLabel(
            String(format: String(
                localized: "widget.streak.lockLabel",
                defaultValue: "Стрик: %d дн."
            ), entry.snapshot.currentStreak)
        )
        .widgetURL(URL(string: "akifi://home"))
    }
}

// MARK: - Widget declaration

struct StreakWidget: Widget {
    let kind = "ru.akifi.widget.streak"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StreakProvider()) { entry in
            FamilyAwareStreakView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(.systemBackground)
                }
        }
        .configurationDisplayName(
            Text(LocalizedStringResource("widget.streak.displayName", defaultValue: "Стрик"))
        )
        .description(
            Text(LocalizedStringResource(
                "widget.streak.description",
                defaultValue: "Сколько дней подряд ты записываешь транзакции"
            ))
        )
        .supportedFamilies([.systemSmall, .accessoryCircular])
        .contentMarginsDisabled()
    }
}

/// Reads `WidgetFamily` from the environment (the Widget-provided
/// view-factory doesn't pass it directly to the SwiftUI view) and
/// forwards to the right `StreakWidgetView` flavour.
private struct FamilyAwareStreakView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        StreakWidgetView(entry: entry, family: family)
    }
}
