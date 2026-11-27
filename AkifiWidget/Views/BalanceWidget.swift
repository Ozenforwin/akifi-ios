import SwiftUI
import WidgetKit

/// Small home-screen widget showing the user's total balance across all
/// accounts, normalized to the base currency.
///
/// Design: hero number (monospaced, large), subtle icon, accounts-count
/// subtitle, tinted gradient background. Tap → main app home.
struct BalanceWidgetView: View {
    let snapshot: SharedSnapshot

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

                Text(WidgetFormatters.amount(snapshot.totalBalance, snapshot: snapshot))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                    .accessibilityLabel(
                        String(localized: "widget.balance.title", defaultValue: "Баланс")
                    )
                    .accessibilityValue(
                        WidgetFormatters.amount(snapshot.totalBalance, snapshot: snapshot)
                    )

                // Plural forms live in Localizable.stringsdict ("На 1 счёте").
                Text(String(localized: "widget.balance.accounts \(snapshot.accountCount)"))
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
    let kind = AkifiWidgetKind.balance

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BalanceProvider()) { entry in
            Group {
                if let snapshot = entry.snapshot {
                    BalanceWidgetView(snapshot: snapshot)
                } else {
                    WidgetEmptyStateView(
                        systemImage: "banknote.fill",
                        title: LocalizedStringResource("widget.balance.title", defaultValue: "Баланс")
                    )
                }
            }
                .containerBackground(for: .widget) {
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.12), Color(.systemBackground)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
        }
        .configurationDisplayName(
            Text(LocalizedStringResource("widget.balance.displayName", defaultValue: "Баланс"))
        )
        .description(
            Text(LocalizedStringResource(
                "widget.balance.description",
                defaultValue: "Сумма по всем счетам в базовой валюте"
            ))
        )
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}
