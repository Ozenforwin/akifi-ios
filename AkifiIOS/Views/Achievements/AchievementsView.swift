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

                // Skill tree entry point
                NavigationLink {
                    SkillTreeView()
                } label: {
                    skillTreeCard
                }
                .buttonStyle(.plain)

                // Category filter
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(categories, id: \.1) { cat, label in
                            FilterChip(title: label, isSelected: viewModel.selectedCategory == cat) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    viewModel.selectedCategory = cat
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.horizontal, -16)

                // Achievement grid
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(viewModel.filteredAchievements) { achievement in
                        AchievementBadgeView(
                            achievement: achievement,
                            isUnlocked: viewModel.isUnlocked(achievement),
                            progress: viewModel.progress(for: achievement)
                        )
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .background(Color(.systemGroupedBackground))
        .akifiFloatingButtonClearance()
        .navigationTitle(String(localized: "achievements.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load()
        }
        .refreshable {
            await viewModel.load()
        }
    }

    // MARK: - Skill Tree Card

    private var skillTreeCard: some View {
        HStack(spacing: 14) {
            SettingsIconTile(systemName: "tree.fill", color: .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "skills.entry.title"))
                    .font(.body.weight(.semibold))
                Text(String(localized: "skills.entry.subtitle"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .akifiCard()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.accent)
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
                ProgressView(value: min(max(info.progress, 0), 1))
                    .tint(Color.accent)

                HStack {
                    Text("\(info.currentXP) XP")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Text("\(info.nextLevelXP) XP")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .akifiCard()
    }
}
