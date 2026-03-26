import Foundation

@Observable @MainActor
final class AchievementsViewModel {
    var achievements: [Achievement] = []
    var userAchievements: [UserAchievement] = []
    var isLoading = false
    var error: String?
    var selectedCategory: AchievementCategory?

    private let repo = AchievementRepository()

    var totalPoints: Int {
        unlockedAchievements.reduce(0) { total, pair in
            total + pair.achievement.points
        }
    }

    var unlockedAchievements: [(achievement: Achievement, userAchievement: UserAchievement)] {
        achievements.compactMap { achievement in
            guard let ua = userAchievements.first(where: { $0.achievementId == achievement.id }),
                  ua.unlockedAt != nil else { return nil }
            return (achievement, ua)
        }
    }

    var filteredAchievements: [Achievement] {
        guard let category = selectedCategory else { return achievements }
        return achievements.filter { $0.category == category }
    }

    func isUnlocked(_ achievement: Achievement) -> Bool {
        userAchievements.contains { $0.achievementId == achievement.id && $0.unlockedAt != nil }
    }

    func progress(for achievement: Achievement) -> Double {
        userAchievements.first { $0.achievementId == achievement.id }?.progress ?? 0
    }

    func load() async {
        isLoading = true
        error = nil
        do {
            async let a = repo.fetchAll()
            async let ua = repo.fetchUserAchievements()
            achievements = try await a
            userAchievements = try await ua
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
