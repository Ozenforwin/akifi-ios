import SwiftUI

extension View {

    /// Shows `message` in an alert while it is non-nil and clears it when
    /// the alert is dismissed. For view models whose `errorMessage` used to
    /// be written and never displayed (V1, V4).
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert(
            String(localized: "common.error"),
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } }
            ),
            presenting: message.wrappedValue
        ) { _ in
            Button(String(localized: "common.ok"), role: .cancel) { message.wrappedValue = nil }
        } message: { text in
            Text(text)
        }
    }
}
