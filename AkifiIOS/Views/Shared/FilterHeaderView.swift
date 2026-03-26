import SwiftUI

struct FilterHeaderView<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                content
            }
            .padding(.horizontal)
        }
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? Color.accent : .clear)
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
                .overlay {
                    Capsule().stroke(isSelected ? Color.clear : Color.gray.opacity(0.3))
                }
        }
        .buttonStyle(.plain)
    }
}
