import SwiftUI

struct AchievementsView: View {
    @State private var viewModel = AchievementsViewModel()

    private let categories: [(AchievementCategory?, String)] = [
        (nil, String(localized: "common.all")),
        (.gettingStarted, "🚀"),
        (.streaks, "🔥"),
        (.transactions, "📊"),
        (.budgets, "🎯"),
        (.savings, "💰"),
        (.ai, "🤖"),
        (.advanced, "⚡"),
        (.secret, "❓")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Level card
                levelCard

                // Category filter
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(categories, id: \.1) { cat, label in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    viewModel.selectedCategory = cat
                                }
                            } label: {
                                Text(label)
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(viewModel.selectedCategory == cat ? Color.accent : Color(.systemGray6))
                                    .foregroundStyle(viewModel.selectedCategory == cat ? .white : .primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Achievement grid
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 16) {
                    ForEach(viewModel.filteredAchievements) { achievement in
                        AchievementBadgeView(
                            achievement: achievement,
                            isUnlocked: viewModel.isUnlocked(achievement),
                            progress: viewModel.progress(for: achievement)
                        )
                    }
                }

                Color.clear.frame(height: 120)
            }
            .padding(.horizontal)
        }
        .navigationTitle(String(localized: "achievements.title"))
        .task {
            await viewModel.load()
        }
        .refreshable {
            await viewModel.load()
        }
    }

    // MARK: - Level Card

    private var levelCard: some View {
        let info = viewModel.levelInfo

        return VStack(spacing: 16) {
            HStack(alignment: .top) {
                // Level number with gradient
                VStack(alignment: .leading, spacing: 4) {
                    Text("LVL")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .tracking(2)

                    Text("\(info.level)")
                        .font(.system(size: 48, weight: .black, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.accent, Color.aiGradientStart],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                Spacer()

                // Stats
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(Color.tierGold)
                        Text("\(info.currentXP)")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                        Text(String(localized: "achievement.points"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "trophy.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accent)
                        Text("\(viewModel.unlockedCount)/\(viewModel.achievements.count)")
                            .font(.subheadline.weight(.medium).monospacedDigit())
                    }
                }
            }

            // Level name
            Text(info.name)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Progress bar
            VStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(.systemGray5))
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                LinearGradient(
                                    colors: [Color.accent, Color.aiGradientStart],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * info.progress)
                    }
                }
                .frame(height: 10)

                HStack {
                    Text("\(info.currentXP) XP")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(info.nextLevelXP) XP")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.accent.opacity(0.2), lineWidth: 1)
        )
    }
}
