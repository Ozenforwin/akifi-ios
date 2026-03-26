import SwiftUI

struct AchievementBadgeView: View {
    let achievement: Achievement
    let isUnlocked: Bool
    let progress: Double

    private var tierColor: Color {
        switch achievement.tier {
        case .bronze: .brown
        case .silver: .gray
        case .gold: .yellow
        case .diamond: .cyan
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(isUnlocked ? tierColor.opacity(0.15) : .gray.opacity(0.1))
                    .frame(width: 64, height: 64)

                if isUnlocked {
                    Text(achievement.icon)
                        .font(.system(size: 28))
                } else {
                    Image(systemName: achievement.isSecret ? "questionmark" : "lock.fill")
                        .font(.title2)
                        .foregroundStyle(.gray.opacity(0.5))
                }

                // Progress ring for partially completed
                if !isUnlocked && progress > 0 {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(tierColor.gradient, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 64, height: 64)
                        .rotationEffect(.degrees(-90))
                }
            }

            VStack(spacing: 2) {
                Text(isUnlocked || !achievement.isSecret ? achievement.nameRu : "???")
                    .font(.caption2.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .foregroundStyle(isUnlocked ? .primary : .secondary)

                Text("\(achievement.points) очков")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 90)
        .grayscale(isUnlocked ? 0 : 0.8)
    }
}
