import SwiftUI

extension View {
    func glassBackground(cornerRadius: CGFloat = 20) -> some View {
        self
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
    }

    func glassCard() -> some View {
        self
            .padding()
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
    }
}
