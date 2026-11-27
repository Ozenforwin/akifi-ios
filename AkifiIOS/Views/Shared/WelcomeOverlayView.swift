import SwiftUI

/// Per-widget blur overlay for new users (like Telegram Mini App premium pattern).
/// Shows mock content with a light blur, a fade into the screen background
/// (so the call to action stays legible) and a CTA button.
struct DemoBlurOverlay: ViewModifier {
    let hint: String
    let buttonTitle: String
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .blur(radius: 3)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    Button(action: action) {
                        Label(buttonTitle, systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.akifiPrimary)
                    .buttonBorderShape(.capsule)

                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.bottom, 16)
                .padding(.top, 40)
                .frame(maxWidth: .infinity)
                .background(
                    // Legibility fade into the grouped screen background,
                    // not decoration.
                    LinearGradient(
                        colors: [
                            Color(.systemGroupedBackground).opacity(0),
                            Color(.systemGroupedBackground).opacity(0.6),
                            Color(.systemGroupedBackground).opacity(0.95),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
    }
}

extension View {
    func demoBlur(hint: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        modifier(DemoBlurOverlay(hint: hint, buttonTitle: buttonTitle, action: action))
    }
}
