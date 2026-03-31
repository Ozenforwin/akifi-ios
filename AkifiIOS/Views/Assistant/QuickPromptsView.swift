import SwiftUI

struct QuickPromptsView: View {
    let onSelect: (String) -> Void

    private let prompts: [(String, LocalizedStringKey, String)] = [
        ("chart.bar", "assistant.prompt.spending", "assistant.prompt.spending.query"),
        ("list.bullet", "assistant.prompt.categories", "assistant.prompt.categories.query"),
        ("arrow.up.arrow.down", "assistant.prompt.compare", "assistant.prompt.compare.query"),
        ("lightbulb", "assistant.prompt.save", "assistant.prompt.save.query"),
        ("exclamationmark.triangle", "assistant.prompt.anomalies", "assistant.prompt.anomalies.query"),
        ("wallet.bifold", "assistant.prompt.budget", "assistant.prompt.budget.query"),
    ]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(prompts, id: \.2) { icon, displayKey, queryKey in
                Button {
                    onSelect(String(localized: String.LocalizationValue(queryKey)))
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: icon)
                            .font(.subheadline)
                            .foregroundStyle(Color.accent)
                            .frame(width: 24)
                        Text(displayKey)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.06), radius: 2, x: 0, y: 1)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
    }
}
