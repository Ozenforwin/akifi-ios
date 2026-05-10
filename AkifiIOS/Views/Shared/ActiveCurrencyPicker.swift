import SwiftUI

/// Inline currency picker bound to the user's "active currencies" list.
///
/// Renders as a `Menu` for one-tap switching between the user's curated
/// currencies, with a dividers + "All currencies…" entry at the bottom
/// that opens the full searchable `CurrencyPickerView` as an escape
/// hatch when the user needs a code outside their active set.
///
/// ## Why not a sheet everywhere
/// After the ISO-catalog migration the sheet picker became the only path
/// to changing currency in any form. For users who only ever transact in
/// 2-3 currencies that's a regression: open sheet → scroll/search →
/// dismiss, every time. The active-currencies feature gives them back
/// the inline menu while keeping the full catalog one tap away.
///
/// ## Single Text per Menu row
/// SwiftUI's menu-style `Picker`/`Menu` drops every `Text` after the
/// first inside a button row on certain iOS builds (memory note:
/// `feedback_swiftui_picker_rows`). Each `Button` label here uses one
/// interpolated `Text`, NOT an `HStack` of multiple `Text`s.
///
/// ## Selection behaviour
/// If the currently-selected currency is NOT in the active list (e.g.
/// the user picked it via "All currencies…" earlier), the menu still
/// highlights it correctly via the checkmark and shows it inside the
/// trigger label — but it does not silently get added to the active
/// list. Adding to active is a deliberate Settings action.
struct ActiveCurrencyPicker: View {
    @Binding var selection: Currency

    /// Standalone state for the sheet — bound to a `@State` so SwiftUI
    /// re-evaluates when `selection` is mutated by the sheet's picker.
    @State private var showFullPicker = false

    /// `@Bindable` would be ideal but `UserCurrencyPreferences` is a
    /// reference-type singleton that doesn't need a binding here — we
    /// only read from it. Direct reference is fine because @Observable
    /// reads inside `body` register a dependency automatically.
    private let prefs = UserCurrencyPreferences.shared

    var body: some View {
        Menu {
            // Active currencies — fast, one-tap.
            ForEach(prefs.activeCurrencies) { c in
                Button {
                    selection = c
                } label: {
                    // Short label so the row never wraps — Apple's locale
                    // names ("Российский рубль", "Vietnamese Dong") spill
                    // onto a second line in iOS Menus and that looks broken.
                    // Symbol + ISO code identifies the currency well enough
                    // here; the full-name browse experience is the sheet.
                    if c == selection {
                        Label {
                            Text("\(c.symbol)  \(c.code)")
                        } icon: {
                            Image(systemName: "checkmark")
                        }
                    } else {
                        Text("\(c.symbol)  \(c.code)")
                    }
                }
            }

            Divider()

            // Escape hatch — full searchable catalog.
            Button {
                showFullPicker = true
            } label: {
                Label {
                    Text(String(localized: "currencyPicker.allCurrencies"))
                } icon: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        } label: {
            HStack(spacing: 6) {
                // Single interpolated Text — same single-Text rule
                // applies to the trigger label for visual stability
                // across iOS builds.
                Text("\(selection.symbol)  \(selection.code)")
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(String(localized: "common.currency"))
        .accessibilityValue("\(selection.code), \(selection.localizedName)")
        .sheet(isPresented: $showFullPicker) {
            CurrencyPickerView(selection: $selection)
        }
    }
}

#Preview {
    struct PreviewHost: View {
        @State var sel: Currency = .usd
        var body: some View {
            Form {
                HStack {
                    Text("Currency")
                    Spacer()
                    ActiveCurrencyPicker(selection: $sel)
                }
            }
        }
    }
    return PreviewHost()
}
