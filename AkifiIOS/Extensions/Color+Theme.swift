import SwiftUI

extension Color {
    // MARK: - Brand
    static let accent = Color.green
    static let accentLight = Color.green.opacity(0.15)

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

    // MARK: - Chart palette
    static let chartPalette: [Color] = [
        .green, .blue, .orange, .purple, .pink, .cyan, .yellow, .red, .indigo, .mint
    ]
}

extension ShapeStyle where Self == Color {
    static var income: Color { .green }
    static var expense: Color { .red }
    static var transfer: Color { .blue }
}
