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
    @State private var glowOpacity: Double = 0

    private let particles = ["🎉", "🏆", "⭐", "💰", "🎯", "💎", "🔥", "✨", "🥇", "💫", "🌟", "🎊"]

    init(achievementName: String, points: Int, icon: String, tier: String = "bronze", onDismiss: @escaping () -> Void) {
        self.achievementName = achievementName
        self.points = points
        self.icon = icon
        self.tier = tier
        self.onDismiss = onDismiss
    }

    private var tierGradient: LinearGradient {
        switch tier {
        case "gold":
            return LinearGradient(colors: [Color(hex: "#FBBF24"), Color(hex: "#F59E0B"), Color(hex: "#D97706")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "silver":
            return LinearGradient(colors: [Color(hex: "#D1D5DB"), Color(hex: "#9CA3AF"), Color(hex: "#6B7280")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "diamond":
            return LinearGradient(colors: [Color(hex: "#67E8F9"), Color(hex: "#22D3EE"), Color(hex: "#06B6D4")], startPoint: .topLeading, endPoint: .bottomTrailing)
        default:
            return LinearGradient(colors: [Color(hex: "#D97706"), Color(hex: "#B45309"), Color(hex: "#92400E")], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

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

            // Particles
            if showParticles {
                ForEach(0..<particles.count, id: \.self) { i in
                    EmojiParticle(emoji: particles[i], index: i)
                }
            }

            // Card
            if showCard {
                VStack(spacing: 0) {
                    ZStack {
                        Circle()
                            .fill(tierColor.opacity(glowOpacity * 0.3))
                            .frame(width: 160, height: 160)
                            .blur(radius: 30)

                        ZStack {
                            Circle()
                                .fill(tierGradient)
                                .frame(width: 100, height: 100)
                                .shadow(color: tierColor.opacity(0.5), radius: 20, x: 0, y: 8)

                            Text(icon)
                                .font(.system(size: 48))
                        }
                        .scaleEffect(iconScale)
                    }

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
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(tierGradient)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.top, 24)
                    .padding(.horizontal, 24)
                }
                .padding(.vertical, 32)
                .frame(maxWidth: 320)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: tierColor.opacity(0.3), radius: 30, x: 0, y: 10)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.8)),
                    removal: .opacity.combined(with: .scale(scale: 0.9))
                ))
            }
        }
        .onAppear {
            HapticManager.success()

            withAnimation(.spring(duration: 0.6, bounce: 0.3)) { showCard = true }
            withAnimation(.spring(duration: 0.8, bounce: 0.4).delay(0.2)) { iconScale = 1.0 }
            withAnimation(.easeIn(duration: 0.5).delay(0.3)) { glowOpacity = 1.0 }
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
