import SwiftUI

/// «Личная трата — за мой счёт» in the expense form of a SHARED account
/// (contract §B3). Owners and editors may pick another member; everyone
/// else marks only their own spending.
struct PersonalSpendingSection: View {
    @Binding var isOn: Bool
    @Binding var memberId: String?
    let me: String
    let parties: [PersonalDebtRules.Party]
    /// «Оплачено с» is "this account" — the money is the account's own.
    let paidFromSharedMoney: Bool
    let nameFor: (String) -> String

    private var chosen: String { memberId ?? me }

    var body: some View {
        Section {
            Toggle(String(localized: "personalDebt.toggle"), isOn: $isOn.animation())
            if isOn && parties.count > 1 {
                Picker(String(localized: "personalDebt.member"), selection: Binding(
                    get: { memberId ?? me },
                    set: { memberId = $0 }
                )) {
                    ForEach(parties) { party in
                        Text(party.userId == me.lowercased() ? String(localized: "personalDebt.member.me") : nameFor(party.userId))
                            .tag(party.userId)
                    }
                }
                .pickerStyle(.menu)
            }
        } footer: {
            if isOn {
                Text(footer)
            }
        }
    }

    private var footer: String {
        let isMe = chosen.lowercased() == me.lowercased()
        if paidFromSharedMoney {
            return isMe
                ? String(localized: "personalDebt.footer.sharedMoney.me")
                : String(localized: "personalDebt.footer.sharedMoney.other \(nameFor(chosen))")
        }
        return isMe
            ? String(localized: "personalDebt.footer.ownCard.me")
            : String(localized: "personalDebt.footer.ownCard.other \(nameFor(chosen))")
    }
}
