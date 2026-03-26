import SwiftUI

struct AchievementsView: View {
    @State private var viewModel = AchievementsViewModel()

    private let categories: [(AchievementCategory?, String)] = [
        (nil, "Все"),
        (.gettingStarted, "Старт"),
        (.streaks, "Стрики"),
        (.transactions, "Операции"),
        (.budgets, "Бюджеты"),
        (.savings, "Копилка"),
        (.ai, "AI"),
        (.advanced, "Про"),
        (.secret, "Секрет")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Points summary
                HStack(spacing: 24) {
                    VStack {
                        Text("\(viewModel.totalPoints)")
                            .font(.title.weight(.bold))
                            .foregroundStyle(Color.accent)
                        Text("Очков")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack {
                        Text("\(viewModel.unlockedAchievements.count)")
                            .font(.title.weight(.bold))
                        Text("Разблокировано")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack {
                        Text("\(viewModel.achievements.count)")
                            .font(.title.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text("Всего")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20))

                // Category filter
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(categories, id: \.1) { cat, label in
                            Button {
                                viewModel.selectedCategory = cat
                            } label: {
                                Text(label)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(viewModel.selectedCategory == cat ? Color.accent : .clear)
                                    .foregroundStyle(viewModel.selectedCategory == cat ? .white : .primary)
                                    .clipShape(Capsule())
                                    .overlay {
                                        Capsule().stroke(.quaternary)
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Achievement grid
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 16) {
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
        }
        .navigationTitle("Достижения")
        .task {
            await viewModel.load()
        }
        .refreshable {
            await viewModel.load()
        }
    }
}
