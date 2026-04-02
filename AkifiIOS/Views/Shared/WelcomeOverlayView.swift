import SwiftUI

/// Per-widget blur overlay for new users (like Telegram Mini App premium pattern).
/// Shows mock content with a light blur, gradient fade, and a CTA button.
struct DemoBlurOverlay: ViewModifier {
    let hint: String
    let buttonTitle: String
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .blur(radius: 3)
            .allowsHitTesting(false)
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    Button(action: action) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                            Text(buttonTitle)
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.accent)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    }

                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.bottom, 16)
                .padding(.top, 40)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(
                        colors: [
                            Color(.systemBackground).opacity(0),
                            Color(.systemBackground).opacity(0.6),
                            Color(.systemBackground).opacity(0.95),
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
