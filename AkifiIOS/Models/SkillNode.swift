import Foundation

/// A single skill in the Akifi financial skill tree.
///
/// This is a client-only model — nodes aren't persisted. `SkillTreeEngine`
/// derives `unlocked` status purely from local data (transactions, budgets,
/// goals, streak, achievements). Adding / renaming nodes requires no DB
/// migration.
///
/// TODO (Phase 5): visual skill-tree view with connected edges, animations,
/// zoom/pan. For now we expose a flat grid.
enum SkillNodeID: String, CaseIterable, Sendable {
    // Foundation track
    case firstTransaction
    case firstAccount
    case firstBudget
    case firstGoal
    case firstCategory

    // Habit track
    case streak7
    case streak30
    case streak100

    // Diversification track
    case twoAccounts
    case threeCategories

    // Automation track
    case firstSubscription
    case firstRecurringIncome

    // Advanced track
    case savingsMilestone   // any goal ≥50% funded
    case diverseBudgets     // ≥2 active budgets
    case expertReporter     // exported PDF at least once
}

struct SkillNode: Identifiable, Sendable {
    let id: SkillNodeID
    let titleKey: String
    let descriptionKey: String
    let icon: String
    let track: Track
    /// Prerequisite node ids that must be unlocked before this one.
    let prerequisites: [SkillNodeID]

    enum Track: String, CaseIterable, Sendable {
        case foundation
        case habit
        case diversification
        case automation
        case advanced

        var title: String {
            switch self {
            case .foundation: return String(localized: "skills.track.foundation")
            case .habit: return String(localized: "skills.track.habit")
            case .diversification: return String(localized: "skills.track.diversification")
            case .automation: return String(localized: "skills.track.automation")
            case .advanced: return String(localized: "skills.track.advanced")
            }
        }
    }

    var localizedTitle: String { String(localized: String.LocalizationValue(titleKey)) }
    var localizedDescription: String { String(localized: String.LocalizationValue(descriptionKey)) }
}

extension SkillNode {
    /// Canonical definition of all skill nodes. Matching `SkillNodeID` keeps
    /// engine lookup O(1) but this array keeps rendering order deterministic.
    static let all: [SkillNode] = [
        // Foundation
        SkillNode(id: .firstTransaction,
                  titleKey: "skills.firstTransaction.title",
                  descriptionKey: "skills.firstTransaction.desc",
                  icon: "🎯", track: .foundation, prerequisites: []),
        SkillNode(id: .firstAccount,
                  titleKey: "skills.firstAccount.title",
                  descriptionKey: "skills.firstAccount.desc",
                  icon: "💳", track: .foundation, prerequisites: []),
        SkillNode(id: .firstBudget,
                  titleKey: "skills.firstBudget.title",
                  descriptionKey: "skills.firstBudget.desc",
                  icon: "🎛", track: .foundation, prerequisites: [.firstTransaction]),
        SkillNode(id: .firstGoal,
                  titleKey: "skills.firstGoal.title",
                  descriptionKey: "skills.firstGoal.desc",
                  icon: "🏁", track: .foundation, prerequisites: [.firstAccount]),
        SkillNode(id: .firstCategory,
                  titleKey: "skills.firstCategory.title",
                  descriptionKey: "skills.firstCategory.desc",
                  icon: "🏷", track: .foundation, prerequisites: [.firstTransaction]),

        // Habit
        SkillNode(id: .streak7,
                  titleKey: "skills.streak7.title",
                  descriptionKey: "skills.streak7.desc",
                  icon: "🔥", track: .habit, prerequisites: [.firstTransaction]),
        SkillNode(id: .streak30,
                  titleKey: "skills.streak30.title",
                  descriptionKey: "skills.streak30.desc",
                  icon: "💪", track: .habit, prerequisites: [.streak7]),
        SkillNode(id: .streak100,
                  titleKey: "skills.streak100.title",
                  descriptionKey: "skills.streak100.desc",
                  icon: "💯", track: .habit, prerequisites: [.streak30]),

        // Diversification
        SkillNode(id: .twoAccounts,
                  titleKey: "skills.twoAccounts.title",
                  descriptionKey: "skills.twoAccounts.desc",
                  icon: "🏦", track: .diversification, prerequisites: [.firstAccount]),
        SkillNode(id: .threeCategories,
                  titleKey: "skills.threeCategories.title",
                  descriptionKey: "skills.threeCategories.desc",
                  icon: "📊", track: .diversification, prerequisites: [.firstCategory]),

        // Automation
        SkillNode(id: .firstSubscription,
                  titleKey: "skills.firstSubscription.title",
                  descriptionKey: "skills.firstSubscription.desc",
                  icon: "🔁", track: .automation, prerequisites: [.firstTransaction]),
        SkillNode(id: .firstRecurringIncome,
                  titleKey: "skills.firstRecurringIncome.title",
                  descriptionKey: "skills.firstRecurringIncome.desc",
                  icon: "💼", track: .automation, prerequisites: [.firstTransaction]),

        // Advanced
        SkillNode(id: .savingsMilestone,
                  titleKey: "skills.savingsMilestone.title",
                  descriptionKey: "skills.savingsMilestone.desc",
                  icon: "💰", track: .advanced, prerequisites: [.firstGoal]),
        SkillNode(id: .diverseBudgets,
                  titleKey: "skills.diverseBudgets.title",
                  descriptionKey: "skills.diverseBudgets.desc",
                  icon: "🎛", track: .advanced, prerequisites: [.firstBudget]),
        SkillNode(id: .expertReporter,
                  titleKey: "skills.expertReporter.title",
                  descriptionKey: "skills.expertReporter.desc",
                  icon: "📄", track: .advanced, prerequisites: [.firstTransaction])
    ]

    static var byId: [SkillNodeID: SkillNode] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }
}
