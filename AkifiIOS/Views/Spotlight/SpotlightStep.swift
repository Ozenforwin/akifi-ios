import Foundation

// MARK: - Spotlight Targets

enum SpotlightTarget: String, CaseIterable {
    case profileAvatar
    case accountCard
    case summaryCards
    case insightCards
    case fabButton
    case aiButton
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

struct SpotlightStep {
    let target: SpotlightTarget
    let tab: Int
    let titleKey: String
    let descriptionKey: String
    let tooltipPosition: TooltipPosition
    let cornerRadius: CGFloat
    let padding: CGFloat

    static let allSteps: [SpotlightStep] = [
        SpotlightStep(
            target: .profileAvatar, tab: 0,
            titleKey: "spotlight.profile.title",
            descriptionKey: "spotlight.profile.description",
            tooltipPosition: .below, cornerRadius: 20, padding: 6
        ),
        SpotlightStep(
            target: .accountCard, tab: 0,
            titleKey: "spotlight.accountCard.title",
            descriptionKey: "spotlight.accountCard.description",
            tooltipPosition: .below, cornerRadius: 20, padding: 8
        ),
        SpotlightStep(
            target: .summaryCards, tab: 0,
            titleKey: "spotlight.summary.title",
            descriptionKey: "spotlight.summary.description",
            tooltipPosition: .above, cornerRadius: 16, padding: 6
        ),
        SpotlightStep(
            target: .insightCards, tab: 0,
            titleKey: "spotlight.insights.title",
            descriptionKey: "spotlight.insights.description",
            tooltipPosition: .below, cornerRadius: 16, padding: 6
        ),
        SpotlightStep(
            target: .fabButton, tab: 0,
            titleKey: "spotlight.fab.title",
            descriptionKey: "spotlight.fab.description",
            tooltipPosition: .above, cornerRadius: 28, padding: 8
        ),
        SpotlightStep(
            target: .aiButton, tab: 0,
            titleKey: "spotlight.ai.title",
            descriptionKey: "spotlight.ai.description",
            tooltipPosition: .above, cornerRadius: 26, padding: 8
        ),
        SpotlightStep(
            target: .transactionsList, tab: 1,
            titleKey: "spotlight.transactions.title",
            descriptionKey: "spotlight.transactions.description",
            tooltipPosition: .below, cornerRadius: 16, padding: 6
        ),
        SpotlightStep(
            target: .analyticsChart, tab: 2,
            titleKey: "spotlight.analytics.title",
            descriptionKey: "spotlight.analytics.description",
            tooltipPosition: .below, cornerRadius: 16, padding: 6
        ),
        SpotlightStep(
            target: .budgetCard, tab: 3,
            titleKey: "spotlight.budgets.title",
            descriptionKey: "spotlight.budgets.description",
            tooltipPosition: .below, cornerRadius: 16, padding: 6
        ),
        SpotlightStep(
            target: .subscriptions, tab: 3,
            titleKey: "spotlight.subscriptions.title",
            descriptionKey: "spotlight.subscriptions.description",
            tooltipPosition: .above, cornerRadius: 16, padding: 6
        ),
    ]
}
