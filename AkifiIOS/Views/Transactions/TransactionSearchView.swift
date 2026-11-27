import SwiftUI

// Transaction search (1.6). The Transactions tab searches with the system
// `.searchable` field (bottom of the screen on iOS 26) instead of a sheet
// with a hand-made search bar; the matching, the suggestions and the
// history live here so they stay testable.

// MARK: - Matching and suggestions

enum TransactionSearch {
    /// Merchants offered as suggestions (most frequent first).
    static let merchantSuggestionLimit = 10
    /// Description keywords offered after the merchants.
    static let keywordSuggestionLimit = 5

    /// Case-insensitive substring match on the description, the merchant
    /// and the category name. An empty query matches everything.
    static func matches(_ tx: Transaction, query: String, categoryName: String?) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return tx.description?.lowercased().contains(q) == true
            || tx.merchantName?.lowercased().contains(q) == true
            || categoryName?.lowercased().contains(q) == true
    }

    /// Search suggestions for the empty field: the most frequent merchants,
    /// then the most frequent description words (longer than two letters)
    /// that aren't one of those merchants. Ties break alphabetically so the
    /// list doesn't reshuffle between renders.
    static func suggestions(from transactions: [Transaction]) -> [String] {
        var merchantCounts: [String: Int] = [:]
        var wordCounts: [String: Int] = [:]
        for tx in transactions {
            if let merchant = tx.merchantName, !merchant.isEmpty {
                merchantCounts[merchant, default: 0] += 1
            }
            guard let desc = tx.description, !desc.isEmpty else { continue }
            for word in desc.split(separator: " ") {
                let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
                guard trimmed.count > 2 else { continue }
                wordCounts[trimmed.lowercased(), default: 0] += 1
            }
        }
        let merchants = ranked(merchantCounts).prefix(merchantSuggestionLimit)
        let merchantSet = Set(merchants.map { $0.lowercased() })
        let keywords = ranked(wordCounts)
            .filter { !merchantSet.contains($0) }
            .prefix(keywordSuggestionLimit)
        return Array(merchants) + Array(keywords)
    }

    private static func ranked(_ counts: [String: Int]) -> [String] {
        counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }
}

// MARK: - History

/// Recent search terms, newest first, persisted in `UserDefaults` under the
/// key the pre-1.6 search sheet used (existing history carries over).
struct TransactionSearchHistory {
    static let defaultsKey = "searchHistory"
    static let limit = 20

    var defaults: UserDefaults = .standard

    func load() -> [String] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let items = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return items
    }

    func save(_ items: [String]) {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// `history` with `term` moved (or added) to the front, capped at
    /// `limit`. Blank terms leave it unchanged.
    static func adding(_ term: String, to history: [String]) -> [String] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return history }
        var items = history.filter { $0 != trimmed }
        items.insert(trimmed, at: 0)
        return Array(items.prefix(limit))
    }
}

// MARK: - Suggestions list

/// Content of `.searchSuggestions` while the search field is empty:
/// frequent merchants / words and the recent searches (each removable,
/// or all at once).
struct TransactionSearchSuggestions: View {
    let suggestions: [String]
    let history: [String]
    let onPick: (String) -> Void
    let onRemove: (String) -> Void
    let onClearHistory: () -> Void

    var body: some View {
        if !suggestions.isEmpty {
            Section(String(localized: "search.suggestions")) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        onPick(suggestion)
                    } label: {
                        Label {
                            Text(suggestion)
                        } icon: {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                }
            }
        }

        if !history.isEmpty {
            Section {
                ForEach(history, id: \.self) { item in
                    HStack {
                        Button {
                            onPick(item)
                        } label: {
                            Label {
                                Text(item)
                                    .foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            onRemove(item)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "common.delete"))
                    }
                }
            } header: {
                HStack {
                    Text(String(localized: "search.history"))
                    Spacer()
                    Button(String(localized: "search.clearHistory"), role: .destructive, action: onClearHistory)
                        .font(.footnote)
                        .textCase(nil)
                }
            }
        }
    }
}
