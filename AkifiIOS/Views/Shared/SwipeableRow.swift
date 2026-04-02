import SwiftUI
import UIKit

/// Custom swipeable row with circular action icons (Apple Notes/Mail style).
/// Uses @GestureState to prevent stuck offsets when ScrollView cancels the gesture.
struct SwipeableRow<Content: View>: View {
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    var deleteIcon: String = "trash.fill"
    @ViewBuilder var content: () -> Content

    // settledOffset = where the row rests (0 or ±revealWidth)
    // dragDelta = live drag offset (auto-resets to 0 on gesture end/cancel)
    @State private var settledOffset: CGFloat = 0
    @GestureState private var dragDelta: CGFloat = 0
    @State private var isDraggingHorizontally = false

    private let circleSize: CGFloat = 48
    private let revealWidth: CGFloat = 74

    private var currentOffset: CGFloat { settledOffset + dragDelta }

    var body: some View {
        ZStack {
            // Action circles behind content
            actions

            // Main content
            content()
                .offset(x: currentOffset)
        }
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(swipeGesture)
        .onChange(of: dragDelta) { _, newValue in
            // When GestureState resets to 0 (gesture ended/cancelled)
            // and we were dragging, snap the settled offset
            if newValue == 0 && isDraggingHorizontally {
                isDraggingHorizontally = false
                snapSettledOffset()
            }
        }
        .onTapGesture {
            if settledOffset != 0 {
                close()
            }
        }
    }

    // MARK: - Actions View

    @ViewBuilder
    private var actions: some View {
        HStack {
            if currentOffset > 10, onEdit != nil {
                let progress = min(1, currentOffset / revealWidth)
                circleButton(color: .blue, icon: "pencil",
                             label: String(localized: "common.edit"),
                             progress: progress) {
                    close()
                    onEdit?()
                }
            }

            Spacer(minLength: 0)

            if currentOffset < -10, onDelete != nil {
                let progress = min(1, -currentOffset / revealWidth)
                circleButton(color: .red, icon: deleteIcon,
                             label: String(localized: "common.delete"),
                             progress: progress) {
                    close()
                    onDelete?()
                }
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Circle Button

    private func circleButton(
        color: Color, icon: String, label: String,
        progress: CGFloat, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Circle()
                    .fill(color)
                    .frame(width: circleSize, height: circleSize)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .scaleEffect(0.6 + progress * 0.4)
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(color)
                    .opacity(Double(progress))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Gesture

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($dragDelta) { value, state, _ in
                // Direction lock: only handle horizontal drags
                let dx = abs(value.translation.width)
                let dy = abs(value.translation.height)

                // Need clear horizontal intent (1.5x horizontal vs vertical)
                guard dx > dy * 1.5, dx > 12 else { return }

                var raw = value.translation.width

                // Resist if no action on that side
                if (settledOffset + raw) > 0 && onEdit == nil {
                    raw = raw * 0.1
                }
                if (settledOffset + raw) < 0 && onDelete == nil {
                    raw = raw * 0.1
                }

                // Rubber band past cap
                let total = settledOffset + raw
                let cap = revealWidth * 2
                if abs(total) > cap {
                    let excess = abs(total) - cap
                    let capped = cap + excess * 0.15
                    state = (total > 0 ? capped : -capped) - settledOffset
                } else {
                    state = raw
                }
            }
            .onEnded { value in
                isDraggingHorizontally = true

                let dx = abs(value.translation.width)
                let dy = abs(value.translation.height)
                guard dx > dy * 1.5, dx > 12 else {
                    isDraggingHorizontally = false
                    return
                }

                let finalOffset = settledOffset + value.translation.width
                let velocity = value.predictedEndTranslation.width
                let screenWidth = UIScreen.main.bounds.width

                // Full swipe → trigger action
                if finalOffset > screenWidth * 0.4 || velocity > 800, let onEdit {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.spring(response: 0.3)) { settledOffset = 0 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { onEdit() }
                    isDraggingHorizontally = false
                    return
                }
                if finalOffset < -screenWidth * 0.4 || velocity < -800, let onDelete {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.spring(response: 0.3)) { settledOffset = 0 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { onDelete() }
                    isDraggingHorizontally = false
                    return
                }

                // Snap
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    if finalOffset > revealWidth * 0.4 || velocity > 350 {
                        settledOffset = revealWidth
                    } else if finalOffset < -revealWidth * 0.4 || velocity < -350 {
                        settledOffset = -revealWidth
                    } else {
                        settledOffset = 0
                    }
                }
                isDraggingHorizontally = false
            }
    }

    // MARK: - Helpers

    private func snapSettledOffset() {
        // Called when GestureState resets (gesture cancelled by ScrollView)
        // Just snap back to 0 if not already open
        if abs(settledOffset) < revealWidth * 0.4 {
            withAnimation(.spring(response: 0.3)) { settledOffset = 0 }
        }
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            settledOffset = 0
        }
    }
}
