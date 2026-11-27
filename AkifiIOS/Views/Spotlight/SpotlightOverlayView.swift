import SwiftUI

struct SpotlightOverlayView: View {
    let manager: SpotlightManager

    var body: some View {
        if manager.isActive, let step = manager.currentStep {
            ZStack {
                // Dimmed background with cutout
                dimOverlay(step: step)

                // Tooltip
                if let frame = manager.currentFrame {
                    tooltipView(step: step, frame: frame)
                        .transition(.opacity)
                }
            }
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.35), value: manager.currentStepIndex)
        }
    }

    // MARK: - Dim + Cutout

    @ViewBuilder
    private func dimOverlay(step: SpotlightStep) -> some View {
        if let frame = manager.currentFrame {
            Color.black.opacity(0.65)
                .reverseMask {
                    RoundedRectangle(cornerRadius: step.cornerRadius, style: .continuous)
                        .frame(
                            width: frame.width + step.padding * 2,
                            height: frame.height + step.padding * 2
                        )
                        .position(x: frame.midX, y: frame.midY)
                }
                .allowsHitTesting(true)
                .onTapGesture { manager.next() }
        } else {
            Color.black.opacity(0.65)
                .allowsHitTesting(true)
                .onTapGesture { manager.next() }
        }
    }

    // MARK: - Tooltip

    private func tooltipView(step: SpotlightStep, frame: CGRect) -> some View {
        let pos = tooltipPosition(step: step, highlightFrame: frame)

        return VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: String.LocalizationValue(step.titleKey)))
                .font(.headline)
                .foregroundStyle(.primary)

            Text(String(localized: String.LocalizationValue(step.descriptionKey)))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                // Step dots
                HStack(spacing: 4) {
                    ForEach(0..<manager.totalSteps, id: \.self) { i in
                        Circle()
                            .fill(i == manager.currentStepIndex ? Color.accent : Color.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                    }
                }
                .accessibilityHidden(true)

                Spacer()

                Button(String(localized: "spotlight.skip")) {
                    manager.skip()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)

                Button(manager.currentStepIndex == manager.totalSteps - 1
                       ? String(localized: "spotlight.done")
                       : String(localized: "spotlight.next")) {
                    manager.next()
                }
                .buttonStyle(.akifiPrimary)
                .buttonBorderShape(.capsule)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: 320)
        // A content card over the dimmed screen — solid, no shadow, no
        // glass (overlays stay content, design doc §3).
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .position(pos)
    }

    // MARK: - Tooltip Positioning

    private func tooltipPosition(step: SpotlightStep, highlightFrame: CGRect) -> CGPoint {
        let screenWidth = UIScreen.main.bounds.width
        let screenHeight = UIScreen.main.bounds.height
        let tooltipHeight: CGFloat = 140
        let tooltipWidth: CGFloat = 300
        let gap: CGFloat = 16

        let position: TooltipPosition
        if step.tooltipPosition == .below {
            // Check if there's room below
            position = highlightFrame.maxY + tooltipHeight + gap < screenHeight - 80 ? .below : .above
        } else {
            position = highlightFrame.minY - tooltipHeight - gap > 60 ? .above : .below
        }

        let y: CGFloat
        switch position {
        case .above:
            y = highlightFrame.minY - gap - tooltipHeight / 2
        case .below:
            y = highlightFrame.maxY + gap + tooltipHeight / 2
        }

        let x = min(max(tooltipWidth / 2 + 16, highlightFrame.midX), screenWidth - tooltipWidth / 2 - 16)

        return CGPoint(x: x, y: y)
    }
}
