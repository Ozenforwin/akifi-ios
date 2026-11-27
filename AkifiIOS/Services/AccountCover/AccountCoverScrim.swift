import CoreGraphics
import Foundation
import UIKit

/// How bright a cover is where the card puts its text: the brightest spot
/// (relative luminance, 0…1) of the header band and of the balance band.
/// Measured once per image (`AccountCoverImageProcessor.tone`).
struct AccountCoverTone: Equatable, Sendable {
    var top: Double
    var bottom: Double
    /// The brightest spot anywhere (for an even scrim under text that
    /// isn't laid out like the Home card).
    var overall: Double

    init(top: Double, bottom: Double, overall: Double? = nil) {
        self.top = top
        self.bottom = bottom
        self.overall = max(overall ?? 0, top, bottom)
    }

    /// Not measured yet: assume a white photo (the strongest scrim).
    static let unknown = AccountCoverTone(top: 1, bottom: 1)

    /// The card's text bands, as fractions of the card height: the header
    /// (icon, name, «…») and the balance with this month's flow.
    static let topBand: ClosedRange<Double> = 0...0.38
    static let bottomBand: ClosedRange<Double> = 0.52...1
}

/// A decoded cover with its measured tone.
struct AccountCoverImage: Sendable {
    let image: UIImage
    let tone: AccountCoverTone
}

/// The dark scrim between a cover photo and the card's light text.
///
/// Guarantee: wherever text sits, the photo — however bright — is darkened
/// enough for WCAG AA (4.5 : 1; 7 : 1 with Increase Contrast) for every
/// colour the card uses on a cover (`textLuminances`). Dark photos get only
/// a light vignette (`floor`), bright ones as much as they need. The
/// opacities are a pure function of the measured tone, so the guarantee is
/// unit-tested rather than eyeballed.
///
/// SwiftUI composites in gamma-encoded sRGB: a pixel of value v under black
/// at opacity a becomes v·(1−a).
struct AccountCoverScrim: Equatable, Sendable {
    /// Black opacity over the header band and over the balance band (the
    /// gap between them eases from one to the other — `stops`).
    let top: Double
    let bottom: Double
    /// The even alternative (`AccountCoverScrimView(uniform:)`).
    let uniform: Double

    static let floor = (top: 0.20, bottom: 0.30)
    static let maxOpacity = 0.92
    static let normalContrast = 4.5
    static let increasedContrast = 7.0
    /// Headroom over the target: the tone is measured on a downscaled copy.
    static let margin = 1.08

    /// Colours drawn on a cover: white text and symbols, income, expense
    /// (`AccountCoverPalette.cover`).
    static let textHexes: [String] = ["#FFFFFF", AccountCoverScrim.incomeHex, AccountCoverScrim.expenseHex]
    /// Lighter income / expense for a dark scrim (#10B981 / #F43F5E would
    /// fail contrast on it); same meaning, same hue.
    static let incomeHex = "#6EE7B7"
    static let expenseHex = "#FDA4AF"

    static var textLuminances: [Double] { textHexes.map(relativeLuminance(hex:)) }

    /// The automatic scrim: the least darkening that keeps every text
    /// colour at the contrast target over the measured tone.
    static func make(for tone: AccountCoverTone, increasedContrast: Bool = false) -> AccountCoverScrim {
        let target = (increasedContrast ? Self.increasedContrast : normalContrast) * margin
        let darkestText = textLuminances.min() ?? 1
        func needed(_ background: Double) -> Double {
            requiredOpacity(backgroundLuminance: background, textLuminance: darkestText, contrast: target)
        }
        return AccountCoverScrim(
            top: min(max(floor.top, needed(tone.top)), maxOpacity),
            bottom: min(max(floor.bottom, needed(tone.bottom)), maxOpacity),
            uniform: min(max(floor.bottom, needed(tone.overall)), maxOpacity)
        )
    }

    // MARK: - Owner's dimming («Затемнение», accounts.cover_dim)

    /// Contrast at the light end of the slider: WCAG AA for large text —
    /// the balance and the name stay readable however light the owner
    /// goes; the small month figures may soften. Never lighter with
    /// Increase Contrast on (the automatic 7 : 1 is the light end then).
    static let lightestContrast = 3.0
    /// Black opacity at the dark end of the slider.
    static let darkestOpacity = 0.85

    /// The scrim for the owner's `dim` (nil = automatic): per band,
    /// `dim` 0…100 runs from the readability floor to `darkestOpacity`.
    static func make(for tone: AccountCoverTone, increasedContrast: Bool = false, dim: Int?) -> AccountCoverScrim {
        let auto = make(for: tone, increasedContrast: increasedContrast)
        guard let dim else { return auto }
        let lightest = lightestScrim(for: tone, increasedContrast: increasedContrast)
        let t = Double(min(max(dim, 0), 100)) / 100
        func band(_ light: Double) -> Double {
            let dark = max(light, darkestOpacity)
            return min(light + (dark - light) * t, maxOpacity)
        }
        return AccountCoverScrim(top: band(lightest.top), bottom: band(lightest.bottom), uniform: band(lightest.uniform))
    }

    /// Where the automatic scrim sits on the slider (0…100) — the slider's
    /// position while the account is on «Авто». Measured on the balance
    /// band, the one the card is read by.
    static func autoDimPosition(for tone: AccountCoverTone, increasedContrast: Bool = false) -> Int {
        let auto = make(for: tone, increasedContrast: increasedContrast)
        let light = lightestScrim(for: tone, increasedContrast: increasedContrast).bottom
        let dark = max(light, darkestOpacity)
        guard dark - light > 0.0001 else { return 0 }
        let t = (auto.bottom - light) / (dark - light)
        return Int((min(max(t, 0), 1) * 100).rounded())
    }

    /// The slider's light end: the large-text contrast floor (or the
    /// automatic scrim with Increase Contrast on).
    private static func lightestScrim(for tone: AccountCoverTone, increasedContrast: Bool) -> AccountCoverScrim {
        if increasedContrast { return make(for: tone, increasedContrast: true) }
        let target = lightestContrast * margin
        let darkestText = textLuminances.min() ?? 1
        func needed(_ background: Double) -> Double {
            min(requiredOpacity(backgroundLuminance: background, textLuminance: darkestText, contrast: target), maxOpacity)
        }
        return AccountCoverScrim(top: needed(tone.top), bottom: needed(tone.bottom), uniform: needed(tone.overall))
    }

    /// Gradient stops (location, black opacity), top to bottom: flat over
    /// each text band and a smoothstep hand-over between them — monotonic,
    /// so the gap is never lighter than both bands. (A dip to a light
    /// floor between the bands read as a bright stripe across the photo on
    /// device, 2026-11-28; the eased ends leave no visible kink either.)
    var stops: [(location: Double, opacity: Double)] {
        let from = AccountCoverTone.topBand.upperBound
        let to = AccountCoverTone.bottomBand.lowerBound
        var result: [(location: Double, opacity: Double)] = [(0, top)]
        for step in 0...Self.handOverSteps {
            let t = Double(step) / Double(Self.handOverSteps)
            let eased = t * t * (3 - 2 * t)
            result.append((from + (to - from) * t, top + (bottom - top) * eased))
        }
        result.append((1, bottom))
        return result
    }

    /// Stops of the hand-over between the bands (enough that the linear
    /// interpolation between them follows the curve without kinks).
    static let handOverSteps = 8

    // MARK: - Colour math (WCAG 2.x)

    /// Smallest black opacity that brings a background of luminance
    /// `backgroundLuminance` down far enough for `contrast` with text of
    /// `textLuminance`.
    static func requiredOpacity(backgroundLuminance: Double, textLuminance: Double, contrast: Double) -> Double {
        let allowed = (textLuminance + 0.05) / contrast - 0.05
        guard allowed > 0 else { return 1 }
        let background = min(max(backgroundLuminance, 0), 1)
        guard background > allowed else { return 0 }
        // v·(1−a) ≤ encode(allowed), v = encode(background).
        return min(max(1 - encode(allowed) / encode(background), 0), 1)
    }

    /// Luminance of a background of `luminance` under black at `opacity`.
    static func scrimmed(_ luminance: Double, opacity: Double) -> Double {
        decode(encode(min(max(luminance, 0), 1)) * (1 - opacity))
    }

    static func contrastRatio(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func relativeLuminance(hex: String) -> Double {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return 0 }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        return relativeLuminance(r: r, g: g, b: b)
    }

    static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
        0.2126 * decode(r) + 0.7152 * decode(g) + 0.0722 * decode(b)
    }

    /// sRGB → linear.
    static func decode(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// Linear → sRGB.
    static func encode(_ l: Double) -> Double {
        l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055
    }
}
