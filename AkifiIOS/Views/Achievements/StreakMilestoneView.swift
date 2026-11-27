import SwiftUI

/// Full-screen celebration popup for crossing a streak milestone
/// (7/14/30/60/100/180/365 consecutive days with at least one transaction).
///
/// Visually mirrors `LevelUpView` so the gamification surface stays cohesive,
/// but foregrounds the "days" number instead of an achievement icon.
struct StreakMilestoneView: View {
    let info: StreakTracker.MilestoneInfo
    let onDismiss: () -> Void

    @State private var showCard = false
    @State private var showParticles = false
    @State private var numberScale: CGFloat = 0.1
    @State private var daysDisplayed = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var medalSize: CGFloat = 120

    private let particles = ["🔥", "⭐", "🏆", "💪", "✨", "🎉", "💯", "🌟", "⚡", "💎"]

    /// Tier colour of the medal — meaning (bronze … diamond), flat.
    private var tierColor: Color {
        switch info.tier {
        case .diamond: Color(hex: "#22D3EE")
        case .gold: Color(hex: "#FBBF24")
        case .silver: Color(hex: "#9CA3AF")
        case .bronze: Color(hex: "#F97316")
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { dismissAnim() }

            if showParticles && !reduceMotion {
                ForEach(0..<particles.count, id: \.self) { i in
                    StreakParticle(emoji: particles[i], index: i)
                }
            }

            // Card — content over a dimmed screen: solid, no glass, no
            // shadow (design doc §3, celebration overlays).
            if showCard {
                VStack(spacing: 0) {
                    ZStack {
                        Circle()
                            .fill(tierColor)
                        VStack(spacing: 2) {
                            Text("\(daysDisplayed)")
                                .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                                .foregroundStyle(.white)
                                .monospacedDigit()
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                            Text(info.icon)
                                .font(.title2)
                        }
                        .padding(12)
                    }
                    .frame(width: medalSize, height: medalSize)
                    .scaleEffect(numberScale)
                    .accessibilityHidden(true)

                    Text(String(localized: "streak.milestone.reached"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tierColor)
                        .textCase(.uppercase)
                        .tracking(2)
                        .padding(.top, 16)

                    Text(String(localized: String.LocalizationValue(info.titleKey)))
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                        .padding(.horizontal, 24)

                    Text(String(localized: "streak.milestone.subtitle \(info.days)"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                    .padding(.horizontal, 32)

                    Button { dismissAnim() } label: {
                        Text(String(localized: "streak.milestone.continue"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.akifiPrimary)
                    .controlSize(.large)
                    .padding(.top, 24)
                    .padding(.horizontal, 24)
                }
                .padding(.vertical, 32)
                .frame(maxWidth: 340)
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
                numberScale = 1.0
            } else {
                withAnimation(.spring(duration: 0.8, bounce: 0.4).delay(0.15)) { numberScale = 1.0 }
            }
            withAnimation(.spring(duration: 0.5).delay(0.1)) { showParticles = true }

            // Count up days
            let steps = min(info.days, 24)
            for i in 0...steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 + Double(i) * 0.04) {
                    daysDisplayed = Int(Double(info.days) * Double(i) / Double(steps))
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { dismissAnim() }
        }
    }

    private func dismissAnim() {
        withAnimation(.easeOut(duration: 0.3)) {
            showCard = false
            showParticles = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onDismiss() }
    }
}

// MARK: - Particle

private struct StreakParticle: View {
    let emoji: String
    let index: Int
    @State private var offset: CGSize = .zero
    @State private var opacity: Double = 1
    @State private var rotation: Double = 0

    var body: some View {
        Text(emoji)
            .font(.system(size: CGFloat.random(in: 28...44)))
            .accessibilityHidden(true)
            .offset(offset)
            .opacity(opacity)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                let angle = Double(index) * (360.0 / 10.0) * .pi / 180
                let radius = CGFloat.random(in: 150...280)
                withAnimation(.easeOut(duration: Double.random(in: 1.2...2.2)).delay(Double(index) * 0.05)) {
                    offset = CGSize(
                        width: cos(angle) * radius,
                        height: sin(angle) * radius - 120
                    )
                    opacity = 0
                    rotation = Double.random(in: -200...200)
                }
            }
    }
}
