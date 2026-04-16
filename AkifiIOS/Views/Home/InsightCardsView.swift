import SwiftUI

struct InsightCardsView: View {
    @Environment(AppViewModel.self) private var appViewModel
    @AppStorage("insightsExpanded") private var expanded = false
    /// Persistent set of insight IDs the user has dismissed.
    /// Stored as a newline-separated string so it survives relaunches.
    @AppStorage("dismissedInsights") private var dismissedRaw = ""

    private var dismissedSet: Set<String> {
        Set(dismissedRaw.split(separator: "\n").map(String.init))
    }

    private var dataStore: DataStore { appViewModel.dataStore }

    private var insights: [InsightEngine.Insight] {
        let fmt = appViewModel.currencyManager
        let all = InsightEngine.generate(
            InsightEngine.Input(
                transactions: dataStore.transactions,
                categories: dataStore.categories,
                budgets: dataStore.budgets,
                subscriptions: dataStore.subscriptions,
                formatAmount: { amount in fmt.formatAmount(amount.displayAmount) },
                formatAmountInCurrency: { amount, currency in
                    Self.formatInCurrency(amount: amount, currency: currency)
                }
            )
        )
        let skip = dismissedSet
        return all.filter { !skip.contains($0.id) }
    }

    private static let collapsedCount = 2

    var body: some View {
        let all = insights
        guard !all.isEmpty else { return AnyView(EmptyView()) }

        let visible = expanded ? all : Array(all.prefix(Self.collapsedCount))
        let remainder = max(0, all.count - visible.count)

        return AnyView(
            VStack(spacing: 8) {
                ForEach(visible) { insight in
                    InsightCardView(insight: insight, onDismiss: {
                        dismiss(insight)
                    })
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                }

                if remainder > 0 && !expanded {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { expanded = true }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                            Text(String(localized: "insights.showMore.\(remainder)"))
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(.tertiarySystemFill))
                        )
                    }
                    .buttonStyle(.plain)
                } else if expanded && all.count > Self.collapsedCount {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { expanded = false }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.up")
                                .font(.caption.weight(.semibold))
                            Text(String(localized: "insights.showLess"))
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            }
        )
    }

    private func dismiss(_ insight: InsightEngine.Insight) {
        var set = dismissedSet
        set.insert(insight.id)
        dismissedRaw = set.joined(separator: "\n")
    }

    /// Format an amount in the subscription's own currency.
    /// Subscriptions can be in USD, EUR, RUB, etc. — rendering them all in
    /// the user's display currency would be misleading (a $100 Claude sub
    /// showing as ₽100 confuses the user).
    nonisolated static func formatInCurrency(amount: Int64, currency: String?) -> String {
        let code = (currency ?? "RUB").uppercased()
        let symbol: String = switch code {
        case "USD": "$"
        case "EUR": "€"
        case "RUB": "₽"
        case "VND": "₫"
        case "THB": "฿"
        case "IDR": "Rp"
        case "GBP": "£"
        default: code
        }
        let display = Decimal(amount) / 100
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = (code == "RUB" || code == "VND" || code == "THB" || code == "IDR") ? 0 : 2
        formatter.minimumFractionDigits = formatter.maximumFractionDigits
        formatter.groupingSeparator = " "
        let formatted = formatter.string(from: display as NSDecimalNumber) ?? "0"
        // Symbol placement: $/€/£/Rp prefix, others postfix.
        let prefix = (code == "USD" || code == "EUR" || code == "GBP" || code == "IDR")
        return prefix ? "\(symbol)\(formatted)" : "\(formatted) \(symbol)"
    }
}

struct InsightCardView: View {
    let insight: InsightEngine.Insight
    var onDismiss: (() -> Void)? = nil

    @State private var dragOffset: CGFloat = 0
    /// Once the user starts a gesture, we lock in the dominant axis.
    /// - `nil`: haven't decided yet
    /// - `.horizontal`: will consume the drag for dismiss
    /// - `.vertical`: must let the enclosing ScrollView take over
    @State private var gestureAxis: Axis?

    private let dismissThreshold: CGFloat = 100
    private let axisLockDistance: CGFloat = 8

    private var swipeProgress: CGFloat {
        min(1.0, abs(dragOffset) / dismissThreshold)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // Red "trash" indicator revealed under the card as the user swipes left.
            // Mirrors the SwiftUI List.swipeActions look used on transaction rows.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.red.opacity(0.18 + 0.5 * swipeProgress))
                .overlay(
                    HStack {
                        Spacer()
                        Image(systemName: "trash.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .scaleEffect(0.6 + 0.6 * swipeProgress)
                            .opacity(dragOffset < -4 ? 1 : 0)
                            .padding(.trailing, 20)
                    }
                )
                .opacity(dragOffset < 0 ? 1 : 0)

            HStack(spacing: 12) {
                Text(insight.emoji)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(insight.title)
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "sparkles")
                            .font(.caption2)
                            .foregroundStyle(insight.kind.color.opacity(0.6))
                    }
                    Text(insight.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(insight.kind.color.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [insight.kind.color.opacity(0.5), insight.kind.color.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .offset(x: dragOffset)
        }
        .opacity(1.0 - min(abs(dragOffset) / 400, 0.4))
        // `simultaneousGesture` lets the ScrollView still receive the pan for
        // vertical scrolling; we only consume the drag once we've locked in
        // the horizontal axis (after the first few points of movement).
        .simultaneousGesture(
            DragGesture(minimumDistance: axisLockDistance)
                .onChanged { value in
                    if gestureAxis == nil {
                        // First meaningful movement — decide which axis wins.
                        if abs(value.translation.width) > abs(value.translation.height) {
                            gestureAxis = .horizontal
                        } else {
                            gestureAxis = .vertical
                        }
                    }
                    guard gestureAxis == .horizontal else { return }
                    // Swipe left only.
                    let t = min(0, value.translation.width)
                    dragOffset = t
                }
                .onEnded { value in
                    defer { gestureAxis = nil }
                    guard gestureAxis == .horizontal else { return }
                    if -value.translation.width > dismissThreshold {
                        withAnimation(.easeOut(duration: 0.2)) {
                            dragOffset = -500
                        }
                        HapticManager.light()
                        onDismiss?()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .contextMenu {
            if let onDismiss {
                Button(role: .destructive) {
                    HapticManager.light()
                    onDismiss()
                } label: {
                    Label(String(localized: "insights.dismiss"), systemImage: "xmark.circle")
                }
            }
        }
    }
}
