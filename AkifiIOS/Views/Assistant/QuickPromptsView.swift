import SwiftUI

struct QuickPromptsView: View {
    let onSelect: (String) -> Void

    private let prompts = [
        ("chart.bar", "Сколько я потратил в этом месяце?"),
        ("list.bullet", "Покажи расходы по категориям"),
        ("arrow.up.arrow.down", "Сравни расходы с прошлым месяцем"),
        ("lightbulb", "Как мне сэкономить?"),
        ("exclamationmark.triangle", "Есть ли аномалии в расходах?"),
        ("wallet.bifold", "Какой бюджет я превысил?")
    ]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(prompts, id: \.1) { icon, text in
                Button {
                    onSelect(text)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: icon)
                            .font(.subheadline)
                            .foregroundStyle(Color.accent)
                            .frame(width: 24)
                        Text(text)
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
