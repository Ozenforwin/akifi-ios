import SwiftUI

// MARK: - PreferenceKey for collecting element frames

struct SpotlightFramePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [SpotlightTarget: CGRect] = [:]

    static func reduce(value: inout [SpotlightTarget: CGRect], nextValue: () -> [SpotlightTarget: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// MARK: - View Modifier

extension View {
    /// Mark this view as a spotlight target. The view's frame in global coordinates
    /// will be collected via PreferenceKey for the spotlight overlay.
    @ViewBuilder
    func spotlight(_ target: SpotlightTarget?) -> some View {
        if let target {
            self.overlay(
                GeometryReader { geo in
                    Color.clear
                        .preference(
                            key: SpotlightFramePreferenceKey.self,
                            value: [target: geo.frame(in: .global)]
                        )
                }
            )
        } else {
            self
        }
    }
}

// MARK: - Reverse Mask (cutout effect)

extension View {
    /// Creates a "reverse mask" — fills the view, then punches out the mask shape.
    /// Used to create the spotlight cutout in the dimmed overlay.
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask(
            ZStack {
                Rectangle()
                mask()
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
        )
    }
}
