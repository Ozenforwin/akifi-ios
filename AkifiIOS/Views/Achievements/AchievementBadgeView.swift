import SwiftUI

struct AchievementBadgeView: View {
    let achievement: Achievement
    let isUnlocked: Bool
    let progress: Double

    private var tierGradient: LinearGradient {
        switch achievement.tier {
        case .bronze:
            return LinearGradient(colors: [Color(hex: "#D97706"), Color(hex: "#92400E")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .silver:
            return LinearGradient(colors: [Color(hex: "#D1D5DB"), Color(hex: "#6B7280")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .gold:
            return LinearGradient(colors: [Color(hex: "#FBBF24"), Color(hex: "#D97706")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .diamond:
            return LinearGradient(colors: [Color(hex: "#67E8F9"), Color(hex: "#06B6D4")], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

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
                        .fill(tierGradient.opacity(0.15))
                        .frame(width: 68, height: 68)
                    Circle()
                        .stroke(tierGradient, lineWidth: 2)
                        .frame(width: 68, height: 68)
                } else {
                    Circle()
                        .fill(Color(.systemGray6))
                        .frame(width: 68, height: 68)
                }

                // Icon or lock
                if isUnlocked {
                    Text(achievement.icon)
                        .font(.system(size: 30))
                } else {
                    Image(systemName: achievement.isSecret ? "questionmark" : "lock.fill")
                        .font(.title2)
                        .foregroundStyle(Color(.systemGray3))
                }

                // Progress ring
                if !isUnlocked && progress > 0 {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(tierGradient, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 68, height: 68)
                        .rotationEffect(.degrees(-90))
                }

                // Points badge (top-right)
                if isUnlocked {
                    Text("\(achievement.points)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(tierGradient)
                        .clipShape(Capsule())
                        .offset(x: 24, y: -28)
                }
            }

            VStack(spacing: 2) {
                Text(isUnlocked || !achievement.isSecret ? achievement.localizedName : "???")
                    .font(.caption2.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .foregroundStyle(isUnlocked ? .primary : .secondary)
            }
        }
        .frame(width: 95)
        .opacity(isUnlocked ? 1 : 0.6)
    }
}
