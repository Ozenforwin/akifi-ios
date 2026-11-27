import SwiftUI

// Account covers (1.6.0) — the design-system half: the photo behind an
// account card, the legibility scrim over it and the light palette of the
// text on it. Rules: `.claude/design/liquid-glass.md` §11. The card stays
// content (no glass, no shadow, no hairline).
//
// The scrim is NOT a decorative gradient (§4 "remove decorative
// gradients"): it is the minimum darkening that keeps text on an arbitrary
// photo at WCAG AA, computed from the photo itself (`AccountCoverScrim`,
// unit-tested). Screens use these components instead of drawing their own.

// MARK: - Palette

/// Colours of the account card's text and controls — the tinted card's
/// system colours, or light ones over a cover (all of them covered by the
/// scrim's contrast guarantee).
struct AccountCardPalette {
    var primary: Color
    var secondary: Color
    var controlFill: Color
    var income: Color
    var expense: Color
    /// The primary star.
    var mark: Color
    var iconTileFill: Color

    static func tinted(_ accountColor: Color) -> AccountCardPalette {
        AccountCardPalette(
            primary: .primary, secondary: .secondary, controlFill: Color(.tertiarySystemFill),
            income: .income, expense: .expense, mark: accountColor,
            iconTileFill: accountColor.opacity(0.15)
        )
    }

    static let cover = AccountCardPalette(
        primary: .white, secondary: .white, controlFill: .white.opacity(0.22),
        income: Color(hex: AccountCoverScrim.incomeHex), expense: Color(hex: AccountCoverScrim.expenseHex),
        mark: .white, iconTileFill: .white.opacity(0.22)
    )
}

// MARK: - Backdrop

/// The cover photo filling its container, under the scrim. Decorative for
/// VoiceOver.
struct AccountCoverBackdrop: View {
    let cover: AccountCoverImage
    /// Draw the photo (false: only the scrim — the crop screen moves the
    /// photo underneath itself).
    var showsImage = true
    /// Tone override (the crop screen measures the window it shows).
    var tone: AccountCoverTone?
    /// One even scrim instead of the two text bands — for layouts other
    /// than the Home card's (the shared account header).
    var uniformScrim = false

    var body: some View {
        ZStack {
            if showsImage {
                Color.clear
                    .overlay {
                        Image(uiImage: cover.image)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
            }
            AccountCoverScrimView(tone: tone ?? cover.tone, uniform: uniformScrim)
        }
        .accessibilityHidden(true)
    }
}

/// The legibility scrim alone: flat over each text band of the Home card,
/// easing from one to the other in the gap (`AccountCoverScrim.stops`).
struct AccountCoverScrimView: View {
    let tone: AccountCoverTone
    var uniform = false

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let scrim = AccountCoverScrim.make(for: tone, increasedContrast: contrast == .increased)
        Group {
            if uniform || dynamicTypeSize.isAccessibilitySize {
                // Accessibility sizes move the text out of the bands the
                // tone was measured for: one even scrim, strong enough for
                // the brightest spot anywhere.
                Color.black.opacity(scrim.uniform)
            } else {
                LinearGradient(
                    stops: scrim.stops.map { Gradient.Stop(color: .black.opacity($0.opacity), location: $0.location) },
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// The account card's frame with a cover: same padding and corners as
    /// `.akifiCard(tint:)` (20 pt continuous), the photo instead of the
    /// tint, no shadow, no glass.
    func accountCoverCard(_ cover: AccountCoverImage, cornerRadius: CGFloat = CardStyle.Size.regular.cornerRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .padding(CardStyle.Size.regular.defaultPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { AccountCoverBackdrop(cover: cover) }
            .clipShape(shape)
            .contentShape(shape)
            .containerShape(shape)
    }
}
