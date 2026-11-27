import SwiftUI

// MARK: - View Modifier

extension View {
    /// Marks this view as a spotlight target. Its frame in global (window)
    /// coordinates is reported to the `SpotlightManager` in the environment.
    ///
    /// Frames go through the environment rather than a `PreferenceKey`:
    /// since 1.6 targets live inside system `TabView` tabs and navigation-bar
    /// toolbar items, which are hosted separately and don't pass preferences
    /// up to `MainTabView`. A target that disappears (its tab is switched
    /// away, the row is removed) withdraws its frame, so a step never points
    /// at a stale position.
    @ViewBuilder
    func spotlight(_ target: SpotlightTarget?) -> some View {
        if let target {
            modifier(SpotlightAnchor(target: target))
        } else {
            self
        }
    }
}

private struct SpotlightAnchor: ViewModifier {
    @Environment(SpotlightManager.self) private var manager: SpotlightManager?
    let target: SpotlightTarget
    /// Identifies this anchor, so a disappearing old copy of a view can't
    /// withdraw the frame its replacement has just reported.
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geo in
                let frame = geo.frame(in: .global)
                Color.clear
                    .onAppear { manager?.report(target, frame: frame, owner: owner) }
                    .onChange(of: frame) { _, newFrame in
                        manager?.report(target, frame: newFrame, owner: owner)
                    }
                    .onDisappear { manager?.withdraw(target, owner: owner) }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
