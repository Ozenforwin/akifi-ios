import SwiftUI

struct LoadingView: View {
    var message: String = "Загрузка..."

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
