import SwiftUI

struct LevelUpView: View {
    let achievementName: String
    let points: Int
    let icon: String
    let tier: String
    let onDismiss: () -> Void

    @State private var showCard = false
    @State private var showParticles = false
    @State private var iconScale: CGFloat = 0.1
    @State private var pointsDisplayed = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var medalSize: CGFloat = 100

    private let particles = ["🎉", "🏆", "⭐", "💰", "🎯", "💎", "🔥", "✨", "🥇", "💫", "🌟", "🎊"]

    init(achievementName: String, points: Int, icon: String, tier: String = "bronze", onDismiss: @escaping () -> Void) {
        self.achievementName = achievementName
        self.points = points
        self.icon = icon
        self.tier = tier
        self.onDismiss = onDismiss
    }

    /// Tier colour of the medal — meaning (bronze … diamond), flat.
    private var tierColor: Color {
        switch tier {
        case "gold": return Color(hex: "#FBBF24")
        case "silver": return Color(hex: "#9CA3AF")
        case "diamond": return Color(hex: "#22D3EE")
        default: return Color(hex: "#D97706")
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { dismissAnim() }

            // Particles (skipped with Reduce Motion)
            if showParticles && !reduceMotion {
                ForEach(0..<particles.count, id: \.self) { i in
                    EmojiParticle(emoji: particles[i], index: i)
                }
            }

            // Card — content over a dimmed screen: solid, no glass, no
            // shadow (design doc §3, celebration overlays).
            if showCard {
                VStack(spacing: 0) {
                    ZStack {
                        Circle()
                            .fill(tierColor)
                        Text(icon)
                            .font(.largeTitle)
                    }
                    .frame(width: medalSize, height: medalSize)
                    .scaleEffect(iconScale)
                    .accessibilityHidden(true)

                    Text(String(localized: "achievement.unlocked"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tierColor)
                        .textCase(.uppercase)
                        .tracking(2)
                        .padding(.top, 16)

                    Text(achievementName)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                        .padding(.horizontal, 24)

                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.subheadline)
                            .foregroundStyle(tierColor)
                        Text("+\(pointsDisplayed)")
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(tierColor)
                    }
                    .padding(.top, 12)

                    Button { dismissAnim() } label: {
                        Text(String(localized: "achievement.great"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.akifiPrimary)
                    .controlSize(.large)
                    .padding(.top, 24)
                    .padding(.horizontal, 24)
                }
                .padding(.vertical, 32)
                .frame(maxWidth: 320)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                )
                .padding(.horizontal, 24)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.8)),
                    removal: .opacity.combined(with: .scale(scale: 0.9))
                ))
            }
        }
        .onAppear {
            HapticManager.success()

            withAnimation(.spring(duration: 0.6, bounce: 0.3)) { showCard = true }
            if reduceMotion {
                iconScale = 1.0
            } else {
                withAnimation(.spring(duration: 0.8, bounce: 0.4).delay(0.2)) { iconScale = 1.0 }
            }
            withAnimation(.spring(duration: 0.5).delay(0.1)) { showParticles = true }

            // Count-up
            let steps = min(points, 30)
            for i in 0...steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(i) * 0.03) {
                    pointsDisplayed = Int(Double(points) * Double(i) / Double(steps))
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { dismissAnim() }
        }
    }

    private func dismissAnim() {
        withAnimation(.easeOut(duration: 0.3)) { showCard = false; showParticles = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onDismiss() }
    }
}

// MARK: - Emoji Particle

private struct EmojiParticle: View {
    let emoji: String
    let index: Int
    @State private var offset: CGSize = .zero
    @State private var opacity: Double = 1
    @State private var rotation: Double = 0

    var body: some View {
        Text(emoji)
            .font(.system(size: CGFloat.random(in: 24...40)))
            .accessibilityHidden(true)
            .offset(offset)
            .opacity(opacity)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                let angle = Double(index) * (360.0 / 12.0) * .pi / 180
                let radius = CGFloat.random(in: 140...250)
                withAnimation(.easeOut(duration: Double.random(in: 1.2...2.0)).delay(Double(index) * 0.05)) {
                    offset = CGSize(width: cos(angle) * radius, height: sin(angle) * radius - 100)
                    opacity = 0
                    rotation = Double.random(in: -180...180)
                }
            }
    }
}
