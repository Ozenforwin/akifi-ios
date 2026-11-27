import SwiftUI

// Shared by the app (tests render the widget views) and the widget
// extension, which links neither `Color(hex:)` nor `CurrencyManager`.

/// The app's colour tokens (`Color+Theme.swift`) for the widgets.
enum WidgetPalette {
    static let accent = Color(red: 0x3B / 255, green: 0x82 / 255, blue: 0xF6 / 255)
    static let income = Color(red: 0x10 / 255, green: 0xB9 / 255, blue: 0x81 / 255)
    static let expense = Color(red: 0xF4 / 255, green: 0x3F / 255, blue: 0x5E / 255)

    /// Wash opacities of a coloured card (`CardStyle.tintWash` in the app).
    static let wash: (start: Double, end: Double) = (0.10, 0.22)

    /// "#RGB", "#RRGGBB" or "#AARRGGBB" → colour; nil when it isn't hex
    /// (the widget then uses the accent, never black).
    static func color(hex: String) -> Color? {
        let digits = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard [3, 6, 8].contains(digits.count),
              digits.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }),
              let value = UInt64(digits, radix: 16) else { return nil }
        let r, g, b, a: UInt64
        switch digits.count {
        case 3: (a, r, g, b) = (255, (value >> 8) * 17, (value >> 4 & 0xF) * 17, (value & 0xF) * 17)
        case 6: (a, r, g, b) = (255, value >> 16, value >> 8 & 0xFF, value & 0xFF)
        default: (a, r, g, b) = (value >> 24, value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF)
        }
        return Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

/// Money text for the widgets, in the style of the app's
/// `CurrencyManager.formatInCurrency`: «85 400 ₽», «1 234,56 $».
enum WidgetMoney {
    /// What a hidden balance shows (the eye on the Home card).
    static let hidden = "••••"

    /// `minor` is the app's Int64 convention: main units × 100 for every
    /// currency; `decimals` is how many of them to show.
    static func format(
        _ minor: Int64,
        symbol: String,
        decimals: Int,
        sign: Sign = .negativeOnly,
        locale: Locale = .current
    ) -> String {
        let value = (Decimal(minor) / 100)
        let magnitude = value < 0 ? -value : value
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = max(0, decimals)
        formatter.maximumFractionDigits = max(0, decimals)
        formatter.roundingMode = .halfUp
        let body = formatter.string(from: magnitude as NSDecimalNumber) ?? "0"
        let prefix: String
        switch sign {
        case .negativeOnly: prefix = value < 0 ? "−" : ""
        case .plus: prefix = value == 0 ? "" : "+"
        case .minus: prefix = value == 0 ? "" : "−"
        }
        return symbol.isEmpty ? "\(prefix)\(body)" : "\(prefix)\(body) \(symbol)"
    }

    enum Sign {
        /// «−1 200 ₽» for a negative balance, nothing for a positive one.
        case negativeOnly
        /// Income: «+1 200 ₽».
        case plus
        /// Expense (stored positive): «−1 200 ₽».
        case minus
    }

    static func balance(_ account: SharedSnapshot.AccountItem) -> String {
        account.isBalanceHidden
            ? hidden
            : format(account.balance, symbol: account.currencySymbol, decimals: account.currencyDecimals)
    }

    static func income(_ account: SharedSnapshot.AccountItem) -> String {
        account.isBalanceHidden
            ? hidden
            : format(account.monthIncome, symbol: account.currencySymbol, decimals: account.currencyDecimals, sign: .plus)
    }

    static func expense(_ account: SharedSnapshot.AccountItem) -> String {
        account.isBalanceHidden
            ? hidden
            : format(account.monthExpense, symbol: account.currencySymbol, decimals: account.currencyDecimals, sign: .minus)
    }
}
