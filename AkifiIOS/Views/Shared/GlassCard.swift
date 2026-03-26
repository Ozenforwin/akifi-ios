import SwiftUI

struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 20
    var padding: CGFloat = 16
    let content: Content

    init(cornerRadius: CGFloat = 20, padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
    }
}
