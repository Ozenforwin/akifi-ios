import SwiftUI

/// Launch splash: the app icon and name on the plain system background
/// (1.6 — no animated gradient, glow or shadow). The entrance animation is
/// skipped with Reduce Motion.
struct SplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var logoSize: CGFloat = 120
    @State private var logoScale: CGFloat = 0.6
    @State private var logoOpacity: Double = 0
    @State private var textOpacity: Double = 0

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Image("AkifiLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: logoSize, height: logoSize)
                    .clipShape(RoundedRectangle(cornerRadius: logoSize * 0.23, style: .continuous))
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text("Akifi")
                        .font(.largeTitle.weight(.bold))
                        .fontDesign(.rounded)
                        .foregroundStyle(.primary)

                    Text(String(localized: "splash.tagline"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .opacity(textOpacity)

                ProgressView()
                    .padding(.top, 24)
                    .opacity(textOpacity)
            }
            .padding(.horizontal, 24)
        }
        .onAppear {
            guard !reduceMotion else {
                logoScale = 1
                logoOpacity = 1
                textOpacity = 1
                return
            }
            withAnimation(.spring(duration: 0.7, bounce: 0.3)) {
                logoScale = 1.0
                logoOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.3)) {
                textOpacity = 1.0
            }
        }
    }
}
