import SwiftUI

/// Searchable currency picker.
///
/// Replaces the inline `Picker { ForEach(CurrencyCode.allCases) }` pattern
/// that used to live in 11+ form views. Now that the catalog has 150+
/// ISO codes (instead of 9), a flat menu would be unusable — this view
/// gives the user search-by-code/name plus a "Popular" shortcut section.
///
/// ## Row layout
/// One `Text` per row with string interpolation. Multi-`Text` rows in a
/// menu-style `List` get all but the first `Text` dropped on certain
/// iOS builds (memory note: `feedback_swiftui_picker_rows`). Single
/// interpolated `Text` is the safe pattern.
///
/// ## Localization
/// Title and section headers use the `currencyPicker.*` keys added in
/// this refactor. The currency name itself comes from
/// `Locale.current.localizedString(forCurrencyCode:)`, so it follows
/// the system language without needing per-currency translation entries.
struct CurrencyPickerView: View {
    @Binding var selection: Currency
    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""

    var body: some View {
        NavigationStack {
            List {
                if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section {
                        ForEach(CurrencyCatalog.popular) { currency in
                            row(for: currency)
                        }
                    } header: {
                        Text(String(localized: "currencyPicker.popular"))
                    }

                    Section {
                        ForEach(CurrencyCatalog.all) { currency in
                            row(for: currency)
                        }
                    } header: {
                        Text(String(localized: "currencyPicker.all"))
                    }
                } else {
                    Section {
                        ForEach(CurrencyCatalog.search(searchText)) { currency in
                            row(for: currency)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text(String(localized: "currencyPicker.searchPlaceholder"))
            )
            .navigationTitle(String(localized: "currencyPicker.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for currency: Currency) -> some View {
        Button {
            selection = currency
            dismiss()
        } label: {
            HStack(spacing: 12) {
                // Single interpolated Text — see header doc-comment.
                Text("\(currency.symbol)  \(currency.code) — \(currency.localizedName)")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if currency == selection {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accent)
                }
            }
            .frame(minHeight: 44) // 44pt touch target.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(currency.code), \(currency.localizedName)")
    }
}

#Preview {
    struct PreviewHost: View {
        @State var sel: Currency = .usd
        var body: some View {
            CurrencyPickerView(selection: $sel)
        }
    }
    return PreviewHost()
}
