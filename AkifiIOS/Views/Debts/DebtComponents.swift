import SwiftUI

/// Round initials avatar for a person (content, not glass).
struct DebtAvatar: View {
    let name: String
    let color: String?
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 40

    var body: some View {
        Circle()
            .fill(tint.opacity(0.18))
            .frame(width: size, height: size)
            .overlay {
                Text(Self.initials(of: name))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
            }
            .accessibilityHidden(true)
    }

    private var tint: Color { Color(hex: color ?? DebtDefaults.color) }

    /// "Маша Петрова" → "МП", "маша" → "М", "" → "?".
    static func initials(of name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace }).prefix(2)
        let letters = words.compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }
}

/// Formatting shared by the «Долги» screens. Debt amounts are shown in the
/// debt's OWN currency (no FX); only the Home / Net Worth one-line totals
/// convert into the display currency.
enum DebtFormat {
    @MainActor
    static func amount(_ minor: Int64, currency: String, cm: CurrencyManager) -> String {
        let code = Currency(code: currency) ?? Currency(unchecked: currency)
        return cm.formatInCurrency(Decimal(abs(minor)) / 100, currency: code)
    }

    /// «Должен вам» / «Вы должны» / «В расчёте».
    static func directionCaption(_ direction: DebtDirection) -> String {
        switch direction {
        case .owedToMe: return String(localized: "debts.direction.owedToMe")
        case .iOwe: return String(localized: "debts.direction.iOwe")
        case .settled: return String(localized: "debts.direction.settled")
        }
    }

    static func color(_ direction: DebtDirection) -> Color {
        switch direction {
        case .owedToMe: return .income
        case .iOwe: return .expense
        case .settled: return .secondary
        }
    }

    /// "yyyy-MM-dd" → localized medium date.
    static func dueDate(_ raw: String?) -> String? {
        guard let day = AppDateFormatters.day(raw) else { return nil }
        return AppDateFormatters.dayMonthYear.string(from: day)
    }

    /// Text field input ("1 500,50", "1500.5") → main units.
    static func parseAmount(_ text: String) -> Decimal? {
        let cleaned = text
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")), value > 0 else { return nil }
        return value
    }

    /// Main units for the amount field ("1500.5" style, no grouping).
    static func fieldText(_ minor: Int64) -> String {
        let value = Decimal(abs(minor)) / 100
        return NSDecimalNumber(decimal: value).stringValue
    }
}

/// One person in a list: avatar, name, due date / overdue, signed balance.
struct DebtRow: View {
    let entry: DebtEntry
    @Environment(AppViewModel.self) private var appViewModel

    var body: some View {
        HStack(spacing: 12) {
            DebtAvatar(name: entry.name, color: entry.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.body)
                    .lineLimit(1)
                subtitle
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(DebtFormat.amount(entry.balance, currency: entry.currency, cm: appViewModel.currencyManager))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(DebtFormat.color(entry.direction))
                Text(DebtFormat.directionCaption(entry.direction))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var subtitle: some View {
        if entry.isOverdue {
            Label(String(localized: "debts.overdue"), systemImage: "exclamationmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.warning)
        } else if entry.isClosed {
            Text(String(localized: "debts.closed"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let due = DebtFormat.dueDate(entry.dueDate) {
            Label(String(localized: "debts.dueDate.short \(due)"), systemImage: entry.remind ? "bell" : "calendar")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
