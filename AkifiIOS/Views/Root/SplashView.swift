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
                    // Glow behind logo
                    Image("AkifiLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 130, height: 130)
                        .blur(radius: 25)
                        .opacity(0.4)

                    // Main logo
                    Image("AkifiLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .shadow(color: Color(hex: "#8BD2FF").opacity(0.4), radius: 16, x: 0, y: 8)
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
