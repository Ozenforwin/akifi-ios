import Foundation

// MARK: - Level System

struct LevelInfo {
    let level: Int
    let name: String
    let currentXP: Int
    let nextLevelXP: Int
    let progress: Double // 0.0–1.0

    static let thresholds = [0, 50, 150, 350, 600, 1000, 1500, 2500, 4000, 6000]

    static let names: [String] = [
        "Новичок", "Ученик", "Финансист", "Эксперт", "Мастер",
        "Гуру", "Легенда", "Титан", "Чемпион", "Магнат"
    ]

    static func from(totalPoints: Int) -> LevelInfo {
        var level = 1
        for (i, threshold) in thresholds.enumerated() {
            if totalPoints >= threshold { level = i + 1 }
        }
        level = min(level, thresholds.count)

        let currentThreshold = level <= thresholds.count ? thresholds[level - 1] : thresholds.last!
        let nextThreshold = level < thresholds.count ? thresholds[level] : thresholds.last! + 2000
        let xpInLevel = totalPoints - currentThreshold
        let xpNeeded = nextThreshold - currentThreshold
        let progress = xpNeeded > 0 ? min(Double(xpInLevel) / Double(xpNeeded), 1.0) : 1.0

        return LevelInfo(
            level: level,
            name: level <= names.count ? names[level - 1] : names.last!,
            currentXP: totalPoints,
            nextLevelXP: nextThreshold,
            progress: progress
        )
    }
}

// MARK: - ViewModel

@Observable @MainActor
final class AchievementsViewModel {
    var achievements: [Achievement] = []
    var userAchievements: [UserAchievement] = []
    var isLoading = false
    var error: String?
    var selectedCategory: AchievementCategory?

    private let repo = AchievementRepository()

    var totalPoints: Int {
        unlockedAchievements.reduce(0) { $0 + $1.achievement.points }
    }

    var levelInfo: LevelInfo {
        LevelInfo.from(totalPoints: totalPoints)
    }

    var unlockedCount: Int {
        unlockedAchievements.count
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
