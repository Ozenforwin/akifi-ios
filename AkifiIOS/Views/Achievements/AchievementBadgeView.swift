import SwiftUI

/// One achievement in the grid: a round medal tinted with its tier colour
/// (bronze / silver / gold / diamond carry meaning, so they stay — as flat
/// colours, no gradients), a progress ring while locked and the name.
struct AchievementBadgeView: View {
    let achievement: Achievement
    let isUnlocked: Bool
    let progress: Double

    @ScaledMetric(relativeTo: .title) private var medalSize: CGFloat = 64

    private var tierColor: Color {
        switch achievement.tier {
        case .bronze: return Color(hex: "#D97706")
        case .silver: return Color(hex: "#9CA3AF")
        case .gold: return Color(hex: "#FBBF24")
        case .diamond: return Color(hex: "#22D3EE")
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Background circle
                if isUnlocked {
                    Circle()
                        .fill(tierColor.opacity(0.15))
                    Circle()
                        .strokeBorder(tierColor, lineWidth: 2)
                } else {
                    Circle()
                        .fill(Color(.tertiarySystemFill))
                }

                // Icon or lock
                if isUnlocked {
                    Text(achievement.icon)
                        .font(.title)
                } else {
                    Image(systemName: achievement.isSecret ? "questionmark" : "lock.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }

                // Progress ring
                if !isUnlocked && progress > 0 {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(tierColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: medalSize, height: medalSize)
            // Points badge (top-trailing)
            .overlay(alignment: .topTrailing) {
                if isUnlocked {
                    Text("\(achievement.points)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(tierColor, in: Capsule())
                        .offset(x: 6, y: -2)
                }
            }

            Text(isUnlocked || !achievement.isSecret ? achievement.localizedName : "???")
                .font(.caption.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .foregroundStyle(isUnlocked ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity)
        .akifiCard(.compact, padding: 10)
        .opacity(isUnlocked ? 1 : 0.7)
        .accessibilityElement(children: .combine)
    }
}
