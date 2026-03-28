import SwiftUI

struct SplashView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var logoScale: CGFloat = 0.6
    @State private var logoOpacity: Double = 0
    @State private var textOpacity: Double = 0
    @State private var gradientPhase: CGFloat = 0

    private var gradientColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(hex: "#1A1030"),
                Color(hex: "#0D1B2A"),
                Color(hex: "#1A0F0A"),
                Color(hex: "#0A1A10"),
            ]
        } else {
            return [
                Color(hex: "#F8F0FF"),
                Color(hex: "#EEF6FF"),
                Color(hex: "#FFF5F0"),
                Color(hex: "#F0FFF5"),
            ]
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: gradientColors,
                startPoint: UnitPoint(x: 0.5 + cos(gradientPhase) * 0.5, y: 0),
                endPoint: UnitPoint(x: 0.5 + sin(gradientPhase) * 0.5, y: 1)
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                ZStack {
                    Image("AkifiLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 130, height: 130)
                        .blur(radius: 25)
                        .opacity(0.4)

                    Image("AkifiLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .shadow(color: Color(hex: "#8BD2FF").opacity(colorScheme == .dark ? 0.6 : 0.4), radius: 16, x: 0, y: 8)
                }
                .scaleEffect(logoScale)
                .opacity(logoOpacity)

                VStack(spacing: 6) {
                    Text("Akifi")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text(String(localized: "splash.tagline"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .opacity(textOpacity)

                ProgressView()
                    .tint(.secondary)
                    .padding(.top, 24)
                    .opacity(textOpacity)
            }
        }
        .onAppear {
            withAnimation(.spring(duration: 0.7, bounce: 0.3)) {
                logoScale = 1.0
                logoOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.3)) {
                textOpacity = 1.0
            }
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                gradientPhase = .pi * 2
            }
        }
    }
}
