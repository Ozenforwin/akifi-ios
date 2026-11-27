import SwiftUI
import WidgetKit

// «Быстрая запись» widget views (shared with the app for PNG tests; the
// extension wraps them in `QuickAddWidget`). Every tap is a deep link that
// OPENS the quick-entry sheet — nothing is saved from the widget.

enum QuickAddWidgetLinks {
    static func open(_ mode: QuickEntryLaunchMode) -> URL {
        QuickEntryLaunchLink(mode: mode, source: .widget).url
    }

    /// A «Повторить» item's link, or plain quick entry for its type when the
    /// stored string is unusable (never a dead tap).
    static func url(for item: SharedSnapshot.RepeatItem) -> URL {
        if let url = URL(string: item.url), QuickEntryLaunchLink(url: url) != nil { return url }
        return open(item.isIncome ? .income : .expense)
    }
}

struct QuickAddWidgetView: View {
    /// nil without a snapshot (signed out): the buttons still open the app.
    let repeatItems: [SharedSnapshot.RepeatItem]?
    let family: WidgetFamily
    let renderingMode: WidgetRenderingMode

    /// The medium widget's list.
    static let repeatLimit = 3
    /// Width of the button column in the medium widget.
    static let buttonsWidth: CGFloat = 140

    var body: some View {
        switch family {
        case .accessoryCircular:
            QuickAddCircularView()
        case .systemMedium:
            HStack(spacing: 12) {
                // The buttons keep about the small widget's width;
                // «Повторить» gets the rest (names and amounts need it).
                QuickAddButtons(renderingMode: renderingMode)
                    .frame(width: Self.buttonsWidth)
                QuickAddRepeatList(items: Array((repeatItems ?? []).prefix(Self.repeatLimit)), renderingMode: renderingMode)
                    .frame(maxWidth: .infinity)
            }
            .padding(12)
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            // Fallback for the background between the buttons.
            .widgetURL(QuickAddWidgetLinks.open(.expense))
        default:
            QuickAddButtons(renderingMode: renderingMode)
                .padding(12)
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
                // Where a system can't route a `Link` in a small widget, the
                // whole widget is «Расход» — the most common entry.
                .widgetURL(QuickAddWidgetLinks.open(.expense))
        }
    }
}

/// Big «Расход», then «Доход» and the mic.
struct QuickAddButtons: View {
    let renderingMode: WidgetRenderingMode
    @ScaledMetric(relativeTo: .title3) private var micSize: CGFloat = 46

    var body: some View {
        VStack(spacing: 8) {
            Link(destination: QuickAddWidgetLinks.open(.expense)) {
                VStack(spacing: 2) {
                    Image(systemName: "minus")
                        .font(.title2.weight(.bold))
                        .widgetAccentable()
                    Text(LocalizedStringResource("quickEntry.mode.expense", defaultValue: "Расход"))
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(tinted(WidgetPalette.expense))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(fill(WidgetPalette.expense), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .layoutPriority(1)

            HStack(spacing: 8) {
                Link(destination: QuickAddWidgetLinks.open(.income)) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .fontWeight(.bold)
                            .widgetAccentable()
                        Text(LocalizedStringResource("quickEntry.mode.income", defaultValue: "Доход"))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tinted(WidgetPalette.income))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(fill(WidgetPalette.income), in: Capsule())
                    .contentShape(Capsule())
                }

                Link(destination: QuickAddWidgetLinks.open(.voice)) {
                    Image(systemName: "mic.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(tinted(WidgetPalette.accent))
                        .widgetAccentable()
                        .frame(width: micSize)
                        .frame(maxHeight: .infinity)
                        .background(fill(WidgetPalette.accent), in: Capsule())
                        .contentShape(Capsule())
                }
                .accessibilityLabel(Text(LocalizedStringResource("quickEntry.mode.voice", defaultValue: "Голосом")))
            }
            .frame(minHeight: 44, maxHeight: 54)
        }
    }

    private func tinted(_ color: Color) -> Color {
        renderingMode == .fullColor ? color : Color.primary
    }

    private func fill(_ color: Color) -> Color {
        renderingMode == .fullColor ? color.opacity(0.14) : Color.primary.opacity(0.14)
    }
}

/// «Повторить»: up to three recent entries; a tap opens the sheet with it.
struct QuickAddRepeatList: View {
    let items: [SharedSnapshot.RepeatItem]
    let renderingMode: WidgetRenderingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringResource("widget.quickAdd.repeat", defaultValue: "Повторить"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if items.isEmpty {
                Text(LocalizedStringResource("widget.quickAdd.repeat.empty", defaultValue: "Здесь появятся ваши частые записи"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ForEach(items) { item in
                    Link(destination: QuickAddWidgetLinks.url(for: item)) {
                        row(item)
                    }
                    .accessibilityLabel(Text(verbatim: String(
                        format: String(localized: "widget.quickAdd.repeat.a11y", defaultValue: "Повторить: %@"),
                        [item.title, item.amountText, item.accountName].compactMap { $0 }.joined(separator: ", ")
                    )))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Name on top, amount under it — both get the row's full width.
    private func row(_ item: SharedSnapshot.RepeatItem) -> some View {
        HStack(spacing: 8) {
            if let icon = item.icon, !icon.isEmpty {
                Text(verbatim: icon)
                    .font(.body)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: item.title)
                    .font(.footnote)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(verbatim: item.isIncome ? "+\(item.amountText)" : item.amountText)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(renderingMode == .fullColor && item.isIncome ? WidgetPalette.income : Color.secondary)
                    .widgetAccentable()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 40)
        .background(WidgetChipFill.color(renderingMode), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Lock Screen `.accessoryCircular`: «+» → quick entry.
struct QuickAddCircularView: View {
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: "plus")
                .font(.title.weight(.semibold))
                .widgetAccentable()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringResource("widget.quickAdd.new", defaultValue: "Новая запись")))
        .widgetURL(QuickAddWidgetLinks.open(.expense))
    }
}
