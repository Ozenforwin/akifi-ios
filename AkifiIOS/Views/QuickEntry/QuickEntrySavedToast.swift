import SwiftUI
import UIKit

/// «Записано: Кофе 300 ₽ · Отменить» — the small glass banner after a quick
/// entry is saved. Floats with the other top banners of `MainTabView`;
/// disappears by itself (longer with VoiceOver on, so there is time to reach
/// the button).
struct QuickEntrySavedToast: View {
    let saved: QuickEntrySaved
    let onUndo: () -> Void
    let onDismiss: () -> Void

    static let duration: Duration = .seconds(5)
    static let voiceOverDuration: Duration = .seconds(12)

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.income)
                .accessibilityHidden(true)
            Text(saved.toastText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            .accessibilityHint(String(localized: "quickEntry.toast.undo.hint"))
        }
        .akifiGlassBanner(contentInsets: EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 8))
        .accessibilityElement(children: .contain)
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear {
            AccessibilityNotification.Announcement(saved.toastText).post()
        }
        .task(id: saved.id) {
            let duration = UIAccessibility.isVoiceOverRunning ? Self.voiceOverDuration : Self.duration
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            onDismiss()
        }
    }
}
