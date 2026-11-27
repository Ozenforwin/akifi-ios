import Foundation

// MARK: - Spotlight Targets

enum SpotlightTarget: String, CaseIterable {
    case profileAvatar
    case accountCard
    case summaryCards
    case insightCards
    case fabButton
    case transactionsList
    case analyticsChart
    case budgetCard
    case subscriptions
}

// MARK: - Tooltip Position

enum TooltipPosition {
    case above, below
}

// MARK: - Step Definition

/// One stop of the onboarding tour. Every target must be anchored with
/// `.spotlight(_:)` on its `tab`; a step whose target isn't on screen is
/// skipped after `SpotlightManager.anchorGracePeriod`.
struct SpotlightStep {
    let target: SpotlightTarget
    let tab: AppTab
    let titleKey: String
    let descriptionKey: String
    let tooltipPosition: TooltipPosition
    let cornerRadius: CGFloat
    let padding: CGFloat

    static let allSteps: [SpotlightStep] = [
        SpotlightStep(
            target: .profileAvatar, tab: .home,
            titleKey: "spotlight.profile.title",
            descriptionKey: "spotlight.profile.description",
            tooltipPosition: .below, cornerRadius: 20, padding: 6
        ),
        SpotlightStep(
            target: .accountCard, tab: .home,
            titleKey: "spotlight.accountCard.title",
            descriptionKey: "spotlight.accountCard.description",
            tooltipPosition: .below, cornerRadius: 20, padding: 8
        ),
        SpotlightStep(
            target: .summaryCards, tab: .home,
            titleKey: "spotlight.summary.title",
            descriptionKey: "spotlight.summary.description",
            tooltipPosition: .above, cornerRadius: 16, padding: 6
        ),
        SpotlightStep(
            target: .insightCards, tab: .home,
            titleKey: "spotlight.insights.title",
            descriptionKey: "spotlight.insights.description",
            tooltipPosition: .below, cornerRadius: 16, padding: 6
        ),
        SpotlightStep(
            target: .fabButton, tab: .home,
            titleKey: "spotlight.fab.title",
            descriptionKey: "spotlight.fab.description",
            tooltipPosition: .above, cornerRadius: 28, padding: 8
        ),
        // 1.6: no Assistant step. The Assistant is a system tab item now
        // (the trailing round tab) and UIKit offers no public way to get a
        // tab item's frame, so the step would point at nothing. The
        // `spotlight.ai.*` strings stay in the catalog for a future anchor.
        SpotlightStep(
            target: .transactionsList, tab: .transactions,
            titleKey: "spotlight.transactions.title",
            descriptionKey: "spotlight.transactions.description",
            tooltipPosition: .below, cornerRadius: 16, padding: 6
        ),
        SpotlightStep(
            target: .analyticsChart, tab: .analytics,
            titleKey: "spotlight.analytics.title",
            descriptionKey: "spotlight.analytics.description",
            tooltipPosition: .below, cornerRadius: 16, padding: 6
        ),
        SpotlightStep(
            target: .budgetCard, tab: .budgets,
            titleKey: "spotlight.budgets.title",
            descriptionKey: "spotlight.budgets.description",
            tooltipPosition: .below, cornerRadius: 16, padding: 6
        ),
        SpotlightStep(
            target: .subscriptions, tab: .budgets,
            titleKey: "spotlight.subscriptions.title",
            descriptionKey: "spotlight.subscriptions.description",
            tooltipPosition: .above, cornerRadius: 16, padding: 6
        ),
    ]
}
