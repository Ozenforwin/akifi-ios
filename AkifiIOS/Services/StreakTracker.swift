import Foundation

/// Client-side streak tracker.
///
/// A "streak" is the number of consecutive days (ending today) on which the
/// user recorded at least one transaction. This mirrors the implementation
/// already present in `StreakBadgeView.calculateStreak()` but centralises it
/// so milestone detection is deterministic across screens.
///
/// Milestones (in ascending order): 7, 14, 30, 60, 100, 180, 365.
/// The tracker persists the highest milestone previously celebrated in
/// `UserDefaults`, so users don't see the same popup twice. Celebrations are
/// consumed by `StreakMilestoneHost` via `.pendingMilestone`.
enum StreakTracker {

    /// Ordered milestone thresholds.
    static let milestones: [Int] = [7, 14, 30, 60, 100, 180, 365]

    private static let lastCelebratedKey = "streak.lastCelebratedMilestone"
    private static let maxStreakKey = "streak.maxStreakReached"

    // MARK: - Public API

    /// Recompute the current streak from transactions.
    static func currentStreak(from transactions: [Transaction]) -> Int {
        guard !transactions.isEmpty else { return 0 }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let uniqueDates = Set(
            transactions
                .compactMap { df.date(from: $0.date) }
                .map { calendar.startOfDay(for: $0) }
        )

        var streak = 0
        var checkDate = today
        while uniqueDates.contains(checkDate) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: checkDate) else { break }
            checkDate = prev
        }
        return streak
    }

    /// Persisted highest streak the user has ever hit.
    static func maxStreakReached() -> Int {
        UserDefaults.standard.integer(forKey: maxStreakKey)
    }

    private static func persistMaxStreak(_ streak: Int) {
        let current = maxStreakReached()
        if streak > current {
            UserDefaults.standard.set(streak, forKey: maxStreakKey)
        }
    }

    /// If `streak` crosses a milestone threshold that hasn't been celebrated
    /// yet, returns that milestone and records it. Otherwise returns nil.
    ///
    /// Multiple-crossing safety: if a user goes from 5 → 15 directly (e.g. after
    /// a long gap + backfill), we return the highest newly-crossed milestone.
    @discardableResult
    static func detectNewMilestone(currentStreak: Int) -> Int? {
        persistMaxStreak(currentStreak)

        let lastCelebrated = UserDefaults.standard.integer(forKey: lastCelebratedKey)

        // Highest milestone that is <= currentStreak and > lastCelebrated.
        let newly = milestones
            .filter { $0 <= currentStreak && $0 > lastCelebrated }
            .max()

        if let newly {
            UserDefaults.standard.set(newly, forKey: lastCelebratedKey)
            return newly
        }
        return nil
    }

    /// Reset celebration state (debug/testing).
    static func resetCelebrationState() {
        UserDefaults.standard.removeObject(forKey: lastCelebratedKey)
        UserDefaults.standard.removeObject(forKey: maxStreakKey)
    }

    /// Visual/text metadata for a given milestone. Used to build the
    /// celebration popup without hard-coding strings in the view.
    struct MilestoneInfo: Sendable {
        let days: Int
        let tier: Tier
        let titleKey: String
        let icon: String

        enum Tier: String, Sendable {
            case bronze, silver, gold, diamond
        }
    }

    static func info(for days: Int) -> MilestoneInfo {
        switch days {
        case 7:
            return MilestoneInfo(days: 7, tier: .bronze, titleKey: "streak.milestone.7", icon: "🔥")
        case 14:
            return MilestoneInfo(days: 14, tier: .bronze, titleKey: "streak.milestone.14", icon: "💪")
        case 30:
            return MilestoneInfo(days: 30, tier: .silver, titleKey: "streak.milestone.30", icon: "🏆")
        case 60:
            return MilestoneInfo(days: 60, tier: .silver, titleKey: "streak.milestone.60", icon: "⚡")
        case 100:
            return MilestoneInfo(days: 100, tier: .gold, titleKey: "streak.milestone.100", icon: "💯")
        case 180:
            return MilestoneInfo(days: 180, tier: .gold, titleKey: "streak.milestone.180", icon: "🌟")
        case 365:
            return MilestoneInfo(days: 365, tier: .diamond, titleKey: "streak.milestone.365", icon: "💎")
        default:
            return MilestoneInfo(days: days, tier: .bronze, titleKey: "streak.milestone.7", icon: "🔥")
        }
    }
}
