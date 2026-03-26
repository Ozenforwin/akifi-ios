import SwiftUI

struct MessageBubbleView: View {
    let message: AiMessage
    let isUser: Bool

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(.subheadline)
                    .foregroundStyle(isUser ? .white : .primary)
                    .textSelection(.enabled)

                if let intent = message.intent {
                    Text(intent)
                        .font(.caption2)
                        .foregroundStyle(isUser ? .white.opacity(0.7) : .secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                if isUser {
                    RoundedRectangle(cornerRadius: 18).fill(Color.accent.gradient)
                } else {
                    RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground))
                }
            }

            if !isUser { Spacer(minLength: 60) }
        }
    }
}
