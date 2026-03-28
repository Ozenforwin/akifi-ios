import SwiftUI

extension Color {
    // MARK: - Brand
    static let accent = Color(hex: "#3B82F6")
    static let accentLight = Color(hex: "#3B82F6").opacity(0.10)
    static let accentCyan = Color(hex: "#06B6D4")

    // MARK: - AI Gradient
    static let aiGradientStart = Color(hex: "#8B5CF6")
    static let aiGradientEnd = Color(hex: "#3B82F6")

    // MARK: - FAB Gradient
    static let fabStart = Color(hex: "#60A5FA")
    static let fabEnd = Color(hex: "#06B6D4")

    // MARK: - Semantic (matching HTML design)
    static let income = Color(hex: "#10B981")   // emerald-500
    static let expense = Color(hex: "#F43F5E")   // rose-500
    static let transfer = Color(hex: "#3B82F6")  // blue-500
    static let warning = Color(hex: "#F59E0B")   // amber-500
    static let budget = Color(hex: "#8B5CF6")    // violet-500

    // MARK: - Tiers
    static let tierBronze = Color.brown
    static let tierSilver = Color.gray
    static let tierGold = Color(hex: "#FBBF24")
    static let tierDiamond = Color.cyan

    // MARK: - Card backgrounds (flat, no heavy shadows)
    static let cardBackground = Color(.secondarySystemGroupedBackground)
    static let cardSurface = Color(.systemBackground)

    // MARK: - Chart palette
    static let chartPalette: [Color] = [
        Color(hex: "#3B82F6"), Color(hex: "#10B981"), Color(hex: "#F97316"),
        Color(hex: "#8B5CF6"), Color(hex: "#EC4899"), Color(hex: "#06B6D4"),
        Color(hex: "#FBBF24"), Color(hex: "#EF4444"), Color(hex: "#6366F1"),
        Color(hex: "#14B8A6")
    ]
}

extension ShapeStyle where Self == Color {
    static var income: Color { Color(hex: "#10B981") }
    static var expense: Color { Color(hex: "#F43F5E") }
    static var transfer: Color { Color(hex: "#3B82F6") }
}
