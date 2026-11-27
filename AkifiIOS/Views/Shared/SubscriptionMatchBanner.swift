import SwiftUI

/// Non-modal top banner shown when a new transaction was automatically matched
/// to a subscription. Offers a 5-second undo window.
///
/// Driven by `DataStore.pendingAutoMatch`; the banner auto-dismisses after the
/// timer elapses. Tapping "Отменить" calls `dataStore.undoAutoMatch()`.
/// Floating glass banner (1.6, `.akifiGlassBanner`); the countdown runs as a
/// thin line inside its bottom edge.
struct SubscriptionMatchBanner: View {
    let match: DataStore.PendingAutoMatch
    let onUndo: () -> Void
    let onDismiss: () -> Void

    /// Total visible duration of the banner, in seconds.
    private let duration: Double = 5.0

    @State private var progress: Double = 1.0

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "link.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "subscriptions.autoMatch.title"))
                    .font(.subheadline.weight(.semibold))
                Text(String(localized: "subscriptions.autoMatch.body \(match.subscriptionName)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button {
                onUndo()
            } label: {
                Text(String(localized: "common.undo"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accent)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .overlay(alignment: .bottom) {
            // Countdown line, kept clear of the rounded corners.
            GeometryReader { geo in
                Capsule()
                    .fill(Color.accent.opacity(0.7))
                    .frame(width: geo.size.width * progress, height: 2)
            }
            .frame(height: 2)
            .padding(.horizontal, AkifiGlassBanner.cornerRadius / 2)
            .offset(y: 6)
            .accessibilityHidden(true)
        }
        .akifiGlassBanner(contentInsets: EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 8))
        .transition(.move(edge: .top).combined(with: .opacity))
        // One timer per match (V9). The old `.task` ignored cancellation:
        // when a second match replaced the first, the first banner's
        // cancelled sleep returned at once and its `onDismiss` cleared the
        // SECOND match before its undo window had even started.
        .task(id: match.id) {
            progress = 1.0
            withAnimation(.linear(duration: duration)) { progress = 0.0 }
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }
            onDismiss()
        }
    }
}
