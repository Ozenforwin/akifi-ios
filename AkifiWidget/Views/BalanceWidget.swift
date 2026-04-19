import SwiftUI
import WidgetKit

/// Small home-screen widget showing the user's total balance across all
/// accounts, normalized to the base currency.
///
/// Design: hero number (monospaced, large), subtle icon, accounts-count
/// subtitle, tinted gradient background. Tap → main app home.
struct BalanceWidgetView: View {
    let entry: SnapshotEntry

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        ZStack(alignment: .leading) {
            // Background gradient — only when system allows (not in
            // accented/vibrant renderingMode which overrides colour).
            if renderingMode == .fullColor {
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "banknote.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Text(LocalizedStringResource("widget.balance.title", defaultValue: "Баланс"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Text(WidgetFormatters.amount(entry.snapshot.totalBalance, snapshot: entry.snapshot))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                    .accessibilityLabel(
                        LocalizedStringResource("widget.balance.title", defaultValue: "Баланс")
                    )
                    .accessibilityValue(
                        WidgetFormatters.amount(entry.snapshot.totalBalance, snapshot: entry.snapshot)
                    )

                Text(String(
                    format: String(localized: "widget.balance.accounts", defaultValue: "На %d счетах"),
                    entry.snapshot.accountCount
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .widgetURL(URL(string: "akifi://home"))
    }
}

// MARK: - Widget declaration

struct BalanceWidget: Widget {
    let kind = "ru.akifi.widget.balance"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BalanceProvider()) { entry in
            BalanceWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.12), Color(.systemBackground)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
        }
        .configurationDisplayName(
            LocalizedStringResource("widget.balance.displayName", defaultValue: "Баланс")
        )
        .description(
            LocalizedStringResource(
                "widget.balance.description",
                defaultValue: "Сумма по всем счетам в базовой валюте"
            )
        )
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}
