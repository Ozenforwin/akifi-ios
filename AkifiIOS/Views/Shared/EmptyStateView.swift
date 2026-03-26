import SwiftUI

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var description: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.headline)

            if let description {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.green)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity)
    }
}
