import SwiftUI

extension Color {
    // MARK: - Brand
    static let accent = Color(hex: "#3B82F6")
    static let accentLight = Color(hex: "#3B82F6").opacity(0.15)
    static let accentCyan = Color(hex: "#06B6D4")

    // MARK: - AI Gradient
    static let aiGradientStart = Color(hex: "#8B5CF6")
    static let aiGradientEnd = Color(hex: "#3B82F6")

    // MARK: - FAB Gradient
    static let fabStart = Color(hex: "#60A5FA")
    static let fabEnd = Color(hex: "#06B6D4")

    // MARK: - Semantic
    static let income = Color.green
    static let expense = Color.red
    static let transfer = Color.blue
    static let warning = Color.orange
    static let budget = Color.purple

    // MARK: - Tiers
    static let tierBronze = Color.brown
    static let tierSilver = Color.gray
    static let tierGold = Color.yellow
    static let tierDiamond = Color.cyan

    // MARK: - Card backgrounds
    static let cardBackground = Color(.secondarySystemGroupedBackground)
    static let cardSurface = Color(.systemBackground)
    static let cardShadow = Color.black.opacity(0.08)

    // MARK: - Chart palette
    static let chartPalette: [Color] = [
        .blue, .green, .orange, .purple, .pink, .cyan, .yellow, .red, .indigo, .mint
    ]
}

extension ShapeStyle where Self == Color {
    static var income: Color { .green }
    static var expense: Color { .red }
    static var transfer: Color { .blue }
}
