import SwiftUI

// MARK: - Liquid Glass foundation (Akifi 1.6)
//
// Availability-safe building blocks for the navigation / controls layer.
// Rules: `.claude/design/liquid-glass.md`. The deployment target is iOS 18,
// Liquid Glass exists only on iOS 26+, so every glass-only API in the app
// goes through these helpers instead of ad-hoc `#available` checks:
//
// | Helper                      | iOS 26+                         | iOS 18–25 fallback                  |
// |-----------------------------|---------------------------------|-------------------------------------|
// | `.akifiGlass(in:tint:interactive:)` | `.glassEffect(...)`     | `.regularMaterial` (or solid tint)  |
// | `.akifiGlassID(_:in:)`      | `.glassEffectID(_:in:)`         | no-op                               |
// | `AkifiGlassContainer`       | `GlassEffectContainer`          | content as is (plain stack)         |
// | `.akifiPrimary` button      | `.glassProminent`               | `.borderedProminent`                |
// | `.akifiSecondary` button    | `.glass`                        | `.bordered`                         |
// | `.akifiGlassBanner()`       | glass capsule                   | material capsule                    |
// | `.akifiTabBarMinimizeOnScroll()` | `.tabBarMinimizeBehavior(.onScrollDown)` | no-op            |
// | `.akifiBottomBar { … }`     | `safeAreaBar(edge: .bottom)`    | `safeAreaInset` on `.bar`           |
// | `.akifiSearchToolbarMinimize()` | `.searchToolbarBehavior(.minimize)` | no-op (field under the bar) |
// | `.akifiCard()` (content!)   | grouped-background card         | same                                |
//
// Glass is for chrome only (bars, floating buttons, banners). Content —
// cards, rows, charts — uses `.akifiCard()`, never glass.

// MARK: - Rendering mode

/// Which visual language the chrome helpers render with on this device.
///
/// The decision is a pure function of the OS version so it can be unit
/// tested; the helpers below pair it with `#available` (the compiler needs
/// the availability check to call iOS 26 API at all).
enum AkifiGlassRendering: Equatable, Sendable {
    /// iOS 26+: system Liquid Glass (`glassEffect`, glass button styles).
    case liquidGlass
    /// iOS 18–25: classic materials and bordered button styles.
    case material

    /// First OS major version with Liquid Glass.
    static let liquidGlassMinimumMajorVersion = 26

    static func resolve(operatingSystemMajorVersion major: Int) -> AkifiGlassRendering {
        major >= liquidGlassMinimumMajorVersion ? .liquidGlass : .material
    }

    /// The mode of the running OS.
    static var current: AkifiGlassRendering {
        resolve(operatingSystemMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }
}

// MARK: - Glass effect

extension View {
    /// Liquid Glass background in `shape` on iOS 26+, a material (or, when
    /// tinted, a solid tint fill) on earlier systems.
    ///
    /// - Parameters:
    ///   - shape: the glass outline (`Capsule()`, `Circle()`,
    ///     `RoundedRectangle(cornerRadius:style:)`).
    ///   - tint: colours the glass (use for one prominent control, e.g. the
    ///     «+» button). The fallback paints the shape with it so white
    ///     symbols on top stay legible.
    ///   - interactive: the glass reacts to touches (scale/shimmer) — only
    ///     for views that are themselves tappable.
    ///
    /// Reduce Transparency / Increase Contrast are honoured by the system
    /// for both glass and materials.
    @ViewBuilder
    func akifiGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Self.akifiGlassValue(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background {
                if let tint {
                    shape.fill(tint)
                } else {
                    shape.fill(.regularMaterial)
                }
            }
        }
    }

    /// Capsule glass — the common case for small floating controls.
    func akifiGlass(tint: Color? = nil, interactive: Bool = false) -> some View {
        akifiGlass(in: Capsule(), tint: tint, interactive: interactive)
    }

    /// `glassEffectID` on iOS 26+ (lets glass shapes inside one
    /// `AkifiGlassContainer` morph into each other); nothing before.
    @ViewBuilder
    func akifiGlassID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    @available(iOS 26.0, *)
    fileprivate static func akifiGlassValue(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

// MARK: - Glass container

/// Groups glass shapes so they render together, blend when close and morph
/// (with `.akifiGlassID`) — `GlassEffectContainer` on iOS 26+. Before iOS 26
/// the content is returned unchanged: lay it out with your own stack inside,
/// exactly as you would inside `GlassEffectContainer`.
struct AkifiGlassContainer<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Buttons

/// The two call-to-action styles of the app. Use through
/// `.buttonStyle(.akifiPrimary)` / `.buttonStyle(.akifiSecondary)` (or
/// `AkifiButtonStyle.primary` / `.secondary`). Destructive buttons keep
/// `role: .destructive`; the role passes through to the system style.
struct AkifiButtonStyle: PrimitiveButtonStyle {
    enum Kind: Equatable, Sendable {
        /// The main action of a screen or form (one per screen).
        case primary
        /// Any other prominent action next to it.
        case secondary
    }

    /// The system style a kind resolves to — the testable half of the
    /// availability mapping.
    enum SystemStyle: Equatable, Sendable {
        case glassProminent, glass, borderedProminent, bordered
    }

    let kind: Kind

    static let primary = AkifiButtonStyle(kind: .primary)
    static let secondary = AkifiButtonStyle(kind: .secondary)

    static func systemStyle(for kind: Kind, rendering: AkifiGlassRendering) -> SystemStyle {
        switch (kind, rendering) {
        case (.primary, .liquidGlass): .glassProminent
        case (.secondary, .liquidGlass): .glass
        case (.primary, .material): .borderedProminent
        case (.secondary, .material): .bordered
        }
    }

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let button = Button(configuration)
        if #available(iOS 26.0, *) {
            switch kind {
            case .primary: button.buttonStyle(.glassProminent)
            case .secondary: button.buttonStyle(.glass)
            }
        } else {
            switch kind {
            case .primary: button.buttonStyle(.borderedProminent)
            case .secondary: button.buttonStyle(.bordered)
            }
        }
    }
}

extension PrimitiveButtonStyle where Self == AkifiButtonStyle {
    /// Primary call to action: `.glassProminent` on iOS 26+, `.borderedProminent` before.
    static var akifiPrimary: AkifiButtonStyle { .primary }
    /// Secondary action: `.glass` on iOS 26+, `.bordered` before.
    static var akifiSecondary: AkifiButtonStyle { .secondary }
}

// MARK: - Content cards (NOT glass)

/// Content card: `secondarySystemGroupedBackground` on a grouped screen
/// background, continuous corners, no shadow, no border. Cards are content —
/// never put glass on them.
struct CardStyle: ViewModifier {
    enum Size: Equatable, Sendable {
        /// Regular content card — 20 pt corners.
        case regular
        /// Small row-like card — 12 pt corners.
        case compact

        var cornerRadius: CGFloat {
            switch self {
            case .regular: 20
            case .compact: 12
            }
        }

        var defaultPadding: CGFloat {
            switch self {
            case .regular: 16
            case .compact: 12
            }
        }
    }

    var size: Size = .regular
    /// Inner padding; `nil` uses the size's default, `0` for edge-to-edge content.
    var padding: CGFloat?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
        content
            .padding(padding ?? size.defaultPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: shape)
            // Nested shapes (`ConcentricRectangle`, `.containerRelative`)
            // follow the card's corners.
            .containerShape(shape)
    }
}

extension View {
    /// Wraps the view in the standard content card (see `CardStyle`).
    func akifiCard(_ size: CardStyle.Size = .regular, padding: CGFloat? = nil) -> some View {
        modifier(CardStyle(size: size, padding: padding))
    }
}

// MARK: - Floating banners

/// Small floating glass banner near the top of the screen (offline state,
/// data problems, undo toasts). A capsule while it fits one line; taller
/// content keeps 24 pt continuous corners so text never runs into the curve.
struct AkifiGlassBanner: ViewModifier {
    static let cornerRadius: CGFloat = 24
    static let defaultInsets = EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)

    /// Padding between the banner's edge and its content. Banners ending in
    /// a 44 pt icon button pass a smaller trailing inset — the button's own
    /// hit area already provides the spacing.
    var contentInsets: EdgeInsets = Self.defaultInsets

    func body(content: Content) -> some View {
        content
            .padding(contentInsets)
            .frame(minHeight: 44)
            .akifiGlass(in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .padding(.horizontal, AkifiChrome.screenEdgeInset)
    }
}

extension View {
    /// Styles the view as a floating glass banner (see `AkifiGlassBanner`).
    func akifiGlassBanner(contentInsets: EdgeInsets = AkifiGlassBanner.defaultInsets) -> some View {
        modifier(AkifiGlassBanner(contentInsets: contentInsets))
    }
}

// MARK: - Search

extension View {
    /// `.searchable` collapses into a toolbar search button that expands
    /// into the glass field when tapped (iOS 26+). Before iOS 26 the field
    /// stays in its usual place under the navigation bar.
    @ViewBuilder
    func akifiSearchToolbarMinimize() -> some View {
        if #available(iOS 26.0, *) {
            self.searchToolbarBehavior(.minimize)
        } else {
            self
        }
    }
}

// MARK: - Bottom bar over scrolling content

extension View {
    /// Pins `content` (a composer, a confirm button) to the bottom edge
    /// above scrolling content. iOS 26+: `safeAreaBar` — the content floats
    /// with the system's soft scroll-edge effect under it, so glass controls
    /// stay legible without an opaque bar. Before iOS 26: `safeAreaInset`
    /// on the classic bar material, the standard look of that system.
    @ViewBuilder
    func akifiBottomBar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(iOS 26.0, *) {
            self.safeAreaBar(edge: .bottom) { content() }
        } else {
            self.safeAreaInset(edge: .bottom) {
                content()
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
    }
}

// MARK: - Chrome metrics

/// Shared measurements of the floating chrome.
enum AkifiChrome {
    /// Horizontal inset of floating banners from the screen edges.
    static let screenEdgeInset: CGFloat = 16

    /// Distance of the top banner stack from the top safe-area edge: the
    /// navigation bar's 44 pt control row plus a small gap, so banners float
    /// over the (large) title, never over toolbar buttons.
    static let bannerTopInset: CGFloat = 50

    /// Trailing inset of the floating «+»: lines up with the trailing edge
    /// of the iOS 26 floating tab bar; the classic bar is edge to edge, so
    /// the standard margin is used there.
    static var floatingButtonTrailingInset: CGFloat {
        floatingButtonTrailingInset(for: .current)
    }

    static func floatingButtonTrailingInset(for rendering: AkifiGlassRendering) -> CGFloat {
        switch rendering {
        case .liquidGlass: 21
        case .material: 16
        }
    }

    /// Bottom room scrolling content needs so its last row can scroll clear
    /// of the floating «+» (button height + gap above the tab bar).
    static let floatingButtonClearance: CGFloat = 56 + 12 + 8

    /// Typical height of the tab bar region (bar + home indicator), used
    /// until the real one has been measured.
    static let estimatedTabBarRegionHeight: CGFloat = 83

    /// Distance from the screen's bottom edge to the bottom of a floating
    /// button that sits `gap` above the tab bar whose top edge is at
    /// `tabBarTop` (global coordinates). A missing or implausible
    /// measurement (at or below the screen bottom — a tab laid out without
    /// the bar) falls back to the estimated tab bar height.
    static func floatingButtonBottomInset(tabBarTop: CGFloat?, screenMaxY: CGFloat, gap: CGFloat) -> CGFloat {
        guard let tabBarTop, tabBarTop > 0, tabBarTop < screenMaxY else {
            return estimatedTabBarRegionHeight + gap
        }
        return screenMaxY - tabBarTop + gap
    }
}

// MARK: - Tab bar

extension View {
    /// The tab bar shrinks while the user scrolls down (iOS 26+). No-op on
    /// earlier systems, whose tab bar doesn't minimise.
    @ViewBuilder
    func akifiTabBarMinimizeOnScroll() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}
