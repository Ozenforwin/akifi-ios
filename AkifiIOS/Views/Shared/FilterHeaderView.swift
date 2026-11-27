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

/// Capsule filter toggle for a row of filters that don't fit a segmented
/// control (tags, many categories). System bordered button styles: the
/// selected chip is prominent (accent), the others plain bordered — both
/// adapt to Liquid Glass on iOS 26 and to Increase Contrast.
struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isSelected {
                Button(action: action) { label }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(action: action) { label }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var label: some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
    }
}
