import SwiftUI
import WidgetKit

/// Medium home-screen widget summarising today's income, expense and net
/// result in 3 columns. Colours: income green, expense red, net coloured
/// by sign (green ≥ 0, red < 0).
struct DaySummaryWidgetView: View {
    let entry: SnapshotEntry

    private var netColor: Color {
        entry.snapshot.todayNet >= 0 ? .green : .red
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.08), Color(.systemBackground)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "calendar")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(LocalizedStringResource("widget.daySummary.title", defaultValue: "Сегодня"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(entry.date.formatted(.dateTime.day().month(.abbreviated)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                HStack(spacing: 0) {
                    column(
                        title: String(localized: "widget.daySummary.income", defaultValue: "Доход"),
                        amount: entry.snapshot.todayIncome,
                        color: .green,
                        sign: "+"
                    )
                    Divider().frame(height: 42)
                    column(
                        title: String(localized: "widget.daySummary.expense", defaultValue: "Расход"),
                        amount: entry.snapshot.todayExpense,
                        color: .red,
                        sign: "−"
                    )
                    Divider().frame(height: 42)
                    column(
                        title: String(localized: "widget.daySummary.net", defaultValue: "Итого"),
                        amount: entry.snapshot.todayNet,
                        color: netColor,
                        sign: entry.snapshot.todayNet >= 0 ? "+" : "−"
                    )
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .widgetURL(URL(string: "akifi://transactions"))
    }

    private func column(
        title: String,
        amount: Int64,
        color: Color,
        sign: String
    ) -> some View {
        VStack(alignment: .center, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)

            let abs: Int64 = amount < 0 ? -amount : amount
            Text("\(sign)\(WidgetFormatters.compactAmount(abs, snapshot: entry.snapshot))")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Widget declaration

struct DaySummaryWidget: Widget {
    let kind = "ru.akifi.widget.daySummary"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DaySummaryProvider()) { entry in
            DaySummaryWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(.systemBackground)
                }
        }
        .configurationDisplayName(
            LocalizedStringResource("widget.daySummary.displayName", defaultValue: "День в цифрах")
        )
        .description(
            LocalizedStringResource(
                "widget.daySummary.description",
                defaultValue: "Доходы и расходы за сегодня"
            )
        )
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}
