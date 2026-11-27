import AppIntents
import Foundation

/// A category the user can pick in Shortcuts / Siri. Only display
/// categories (active, deduplicated — `QuickEntryContext`).
struct QuickEntryCategoryEntity: AppEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "quickEntry.entity.category")
    static let defaultQuery = QuickEntryCategoryQuery()

    let id: String
    let name: String
    let icon: String
    let isIncome: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(icon) \(name)")
    }

    init(_ category: Category) {
        id = category.id
        name = category.name
        icon = category.icon
        isIncome = category.type == .income
    }
}

struct QuickEntryCategoryQuery: EntityStringQuery {
    init() {}

    @MainActor
    func entities(for identifiers: [String]) async throws -> [QuickEntryCategoryEntity] {
        guard let context = await QuickEntryHost.shared.context() else { return [] }
        return identifiers.compactMap { id in context.displayCategory(id).map(QuickEntryCategoryEntity.init) }
    }

    @MainActor
    func suggestedEntities() async throws -> [QuickEntryCategoryEntity] {
        guard let context = await QuickEntryHost.shared.context() else { return [] }
        return context.displayCategories.map(QuickEntryCategoryEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [QuickEntryCategoryEntity] {
        guard let context = await QuickEntryHost.shared.context() else { return [] }
        return QuickEntryIntentSupport.categories(matching: string, in: context.displayCategories)
            .map(QuickEntryCategoryEntity.init)
    }
}

/// Expense categories for `AddExpenseIntent`'s picker.
struct QuickEntryExpenseCategoryOptions: DynamicOptionsProvider {
    @MainActor
    func results() async throws -> [QuickEntryCategoryEntity] {
        guard let context = await QuickEntryHost.shared.context() else { return [] }
        return context.displayCategories(for: .expense).map(QuickEntryCategoryEntity.init)
    }
}

/// Income categories for `AddIncomeIntent`'s picker.
struct QuickEntryIncomeCategoryOptions: DynamicOptionsProvider {
    @MainActor
    func results() async throws -> [QuickEntryCategoryEntity] {
        guard let context = await QuickEntryHost.shared.context() else { return [] }
        return context.displayCategories(for: .income).map(QuickEntryCategoryEntity.init)
    }
}

/// An account the user can pick in Shortcuts / Siri.
struct QuickEntryAccountEntity: AppEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "quickEntry.entity.account")
    static let defaultQuery = QuickEntryAccountQuery()

    let id: String
    let name: String
    let icon: String
    let currency: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(icon) \(name)", subtitle: "\(currency)")
    }

    init(_ account: Account) {
        id = account.id
        name = account.name
        icon = account.icon
        currency = account.currency.uppercased()
    }
}

struct QuickEntryAccountQuery: EntityStringQuery {
    init() {}

    @MainActor
    func entities(for identifiers: [String]) async throws -> [QuickEntryAccountEntity] {
        guard let context = await QuickEntryHost.shared.context() else { return [] }
        return identifiers.compactMap { context.account($0).map(QuickEntryAccountEntity.init) }
    }

    @MainActor
    func suggestedEntities() async throws -> [QuickEntryAccountEntity] {
        guard let context = await QuickEntryHost.shared.context() else { return [] }
        return context.accounts.map(QuickEntryAccountEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [QuickEntryAccountEntity] {
        guard let context = await QuickEntryHost.shared.context() else { return [] }
        let keys = QuickEntryText.matchKeys(string)
        guard !keys.isEmpty else { return context.accounts.map(QuickEntryAccountEntity.init) }
        return context.accounts
            .filter { QuickEntryText.overlap(keys, QuickEntryText.matchKeys($0.name)) > 0 }
            .map(QuickEntryAccountEntity.init)
    }
}
