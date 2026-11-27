import SwiftUI

struct LoadingView: View {
    var message: String = String(localized: "common.loading")

    var body: some View {
        ProgressView {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
