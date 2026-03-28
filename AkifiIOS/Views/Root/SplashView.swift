import SwiftUI

struct SplashView: View {
    @State private var logoScale: CGFloat = 0.6
    @State private var logoOpacity: Double = 0
    @State private var textOpacity: Double = 0
    @State private var gradientPhase: CGFloat = 0
    @State private var shimmerOffset: CGFloat = -200

    var body: some View {
        ZStack {
            // Animated gradient background
            LinearGradient(
                colors: [
                    Color(hex: "#F8F0FF"),
                    Color(hex: "#EEF6FF"),
                    Color(hex: "#FFF5F0"),
                    Color(hex: "#F0FFF5"),
                ],
                startPoint: UnitPoint(x: 0.5 + cos(gradientPhase) * 0.5, y: 0),
                endPoint: UnitPoint(x: 0.5 + sin(gradientPhase) * 0.5, y: 1)
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                // Logo: stylized "A" with gradient
                ZStack {
                    // Glow
                    Text("A")
                        .font(.system(size: 90, weight: .black, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    Color(hex: "#F4A0A0"),
                                    Color(hex: "#F7CE68"),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .blur(radius: 20)
                        .opacity(0.5)

                    // Main letter
                    Text("A")
                        .font(.system(size: 90, weight: .black, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    Color(hex: "#F4A0A0"),
                                    Color(hex: "#F7CE68"),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .shadow(color: Color(hex: "#F4A0A0").opacity(0.3), radius: 12, x: 0, y: 6)

                    // Shimmer overlay
                    Text("A")
                        .font(.system(size: 90, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .white, location: 0.45),
                                    .init(color: .white, location: 0.55),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .offset(x: shimmerOffset)
                        )
                }
                .scaleEffect(logoScale)
                .opacity(logoOpacity)

                // App name
                VStack(spacing: 6) {
                    Text("Akifi")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text("Умные финансы")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .opacity(textOpacity)

                // Loading indicator
                ProgressView()
                    .tint(.secondary)
                    .padding(.top, 24)
                    .opacity(textOpacity)
            }
        }
        .onAppear {
            // Logo entrance
            withAnimation(.spring(duration: 0.7, bounce: 0.3)) {
                logoScale = 1.0
                logoOpacity = 1.0
            }

            // Text fade in
            withAnimation(.easeOut(duration: 0.5).delay(0.3)) {
                textOpacity = 1.0
            }

            // Continuous gradient rotation
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                gradientPhase = .pi * 2
            }

            // Shimmer
            withAnimation(.easeInOut(duration: 1.5).delay(0.5)) {
                shimmerOffset = 200
            }
        }
    }
}
