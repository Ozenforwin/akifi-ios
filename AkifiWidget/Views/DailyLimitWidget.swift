import SwiftUI
import WidgetKit

/// Small home-screen widget showing the user's safe-to-spend-today number
/// for their primary active budget.
///
/// Colour accent follows utilization:
///   green  < 70 %
///   amber  70–89 %
///   orange 90–99 %
///   red    >= 100 %
///
/// Fallback: if `dailyLimit == nil`, prompt the user to create a budget.
struct DailyLimitWidgetView: View {
    let entry: SnapshotEntry

    @Environment(\.widgetRenderingMode) private var renderingMode

    private var limit: Int64? { entry.snapshot.dailyLimit }
    private var status: StatusColour {
        let util = entry.snapshot.dailyLimitUtilization
        switch util {
        case ..<70: return .green
        case 70..<90: return .amber
        case 90..<100: return .orange
        default: return .red
        }
    }

    private var accent: Color {
        switch status {
        case .green: return .green
        case .amber: return .yellow
        case .orange: return .orange
        case .red: return .red
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if renderingMode == .fullColor {
                LinearGradient(
                    colors: [accent.opacity(0.18), accent.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "target")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(accent)
                    Spacer()
                    Text(LocalizedStringResource("widget.dailyLimit.title", defaultValue: "На сегодня"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if let limit {
                    Text(WidgetFormatters.amount(limit, snapshot: entry.snapshot))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                        .accessibilityLabel(
                            String(localized: "widget.dailyLimit.title", defaultValue: "На сегодня")
                        )
                        .accessibilityValue(
                            WidgetFormatters.amount(limit, snapshot: entry.snapshot)
                        )

                    if let name = entry.snapshot.dailyLimitBudgetName {
                        Text(name)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(String(
                        format: String(
                            localized: "widget.dailyLimit.spent",
                            defaultValue: "Сегодня: %@"
                        ),
                        WidgetFormatters.amount(entry.snapshot.dailySpentToday, snapshot: entry.snapshot)
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                } else {
                    Text(LocalizedStringResource(
                        "widget.dailyLimit.empty",
                        defaultValue: "Нет активных бюджетов"
                    ))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                    Text(LocalizedStringResource(
                        "widget.dailyLimit.cta",
                        defaultValue: "Создай бюджет в приложении"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .widgetURL(URL(string: "akifi://budgets"))
    }

    private enum StatusColour { case green, amber, orange, red }
}

// MARK: - Widget declaration

struct DailyLimitWidget: Widget {
    let kind = "ru.akifi.widget.dailyLimit"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DailyLimitProvider()) { entry in
            DailyLimitWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(.systemBackground)
                }
        }
        .configurationDisplayName(
            Text(LocalizedStringResource("widget.dailyLimit.displayName", defaultValue: "Лимит на сегодня"))
        )
        .description(
            Text(LocalizedStringResource(
                "widget.dailyLimit.description",
                defaultValue: "Сколько можно потратить сегодня, чтобы уложиться в бюджет"
            ))
        )
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}
