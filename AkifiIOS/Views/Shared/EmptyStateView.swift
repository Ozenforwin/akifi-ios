import SwiftUI

/// Empty state of a list or screen: the system `ContentUnavailableView`
/// (symbol, title, description) with an optional primary action.
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var description: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let description {
                Text(description)
            }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.akifiPrimary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
