import CoreGraphics

/// The crop of an account cover: a photo under a card-shaped window, zoomed
/// and panned by the user, always filling the window.
///
/// Coordinates: `viewportSize` is the window (points); the photo is drawn
/// at `displayedSize`, its centre `offset` points away from the window's
/// centre. `zoom` 1 = the smallest size that still fills the window
/// ("aspect fill"). Every mutation clamps, so the window can never show
/// anything but the photo.
///
/// The result is `normalizedCropRect` — the window in the photo's unit
/// space (0…1 on both axes, origin top-left), independent of screen size —
/// which `AccountCoverImageProcessor` turns into pixels.
struct AccountCoverCrop: Equatable, Sendable {
    /// Width / height of the Home account card (≈361 × 190 pt on a 6.1″
    /// iPhone). Covers are cut at this ratio; the card fills itself with
    /// the photo (`scaledToFill`), so other widths / Dynamic Type heights
    /// trim a little at the edges.
    static let cardAspect: CGFloat = 1.9
    /// Furthest zoom-in, relative to aspect fill.
    static let maxZoom: CGFloat = 5
    /// Pixel width of the uploaded cover (never upscaled beyond the crop).
    static let outputWidth = 1200

    let imageSize: CGSize
    let viewportSize: CGSize
    private(set) var zoom: CGFloat = 1
    private(set) var offset: CGSize = .zero

    /// - Parameter normalizedCrop: a previous result to start from (the
    ///   «Изменить область» flow); nil starts centred at zoom 1.
    init(imageSize: CGSize, viewportSize: CGSize, normalizedCrop: CGRect? = nil) {
        self.imageSize = CGSize(width: max(imageSize.width, 1), height: max(imageSize.height, 1))
        self.viewportSize = CGSize(width: max(viewportSize.width, 1), height: max(viewportSize.height, 1))
        if let normalizedCrop, normalizedCrop.width > 0, normalizedCrop.height > 0 {
            restore(normalizedCrop)
        }
    }

    // MARK: - Geometry

    /// Points per image unit at zoom 1 (aspect fill).
    var fillScale: CGFloat {
        max(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height)
    }

    var scale: CGFloat { fillScale * zoom }

    var displayedSize: CGSize {
        CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    /// How far the photo's centre may move from the window's centre on each
    /// axis before an edge of the photo would enter the window.
    var maxOffset: CGSize { Self.maxOffset(displayed: displayedSize, viewport: viewportSize) }

    private static func maxOffset(displayed: CGSize, viewport: CGSize) -> CGSize {
        CGSize(width: max(0, (displayed.width - viewport.width) / 2),
               height: max(0, (displayed.height - viewport.height) / 2))
    }

    func clamped(_ proposed: CGSize) -> CGSize {
        let limit = maxOffset
        return CGSize(width: min(max(proposed.width, -limit.width), limit.width),
                      height: min(max(proposed.height, -limit.height), limit.height))
    }

    // MARK: - Mutations (all clamped)

    /// Pans to `proposed` (clamped).
    mutating func setOffset(_ proposed: CGSize) {
        offset = clamped(proposed)
    }

    /// Zooms to `proposed` (clamped to 1…`maxZoom`), keeping the point of
    /// the photo under the window's centre where it is.
    mutating func setZoom(_ proposed: CGFloat) {
        let newZoom = min(max(proposed.isFinite ? proposed : 1, 1), Self.maxZoom)
        let ratio = newZoom / zoom
        zoom = newZoom
        offset = clamped(CGSize(width: offset.width * ratio, height: offset.height * ratio))
    }

    // MARK: - Result

    /// The window in the photo's unit space (origin top-left), clamped to
    /// the photo.
    var normalizedCropRect: CGRect {
        let displayed = displayedSize
        let width = min(viewportSize.width / displayed.width, 1)
        let height = min(viewportSize.height / displayed.height, 1)
        // The window's left edge, measured from the photo's left edge.
        let x = 0.5 - (offset.width + viewportSize.width / 2) / displayed.width
        let y = 0.5 - (offset.height + viewportSize.height / 2) / displayed.height
        return CGRect(x: min(max(x, 0), 1 - width), y: min(max(y, 0), 1 - height),
                      width: width, height: height)
    }

    /// `normalizedCropRect` in pixels of an image of `pixelSize`, integral
    /// and inside the image.
    static func pixelRect(for normalized: CGRect, pixelSize: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: pixelSize)
        let rect = CGRect(x: normalized.minX * pixelSize.width, y: normalized.minY * pixelSize.height,
                          width: normalized.width * pixelSize.width, height: normalized.height * pixelSize.height)
        let integral = rect.integral.intersection(bounds)
        return integral.isNull ? bounds : integral
    }

    /// Pixel size of the uploaded cover for a crop `cropPixelWidth` wide:
    /// `maxWidth` wide (or the crop's own width when it is smaller — never
    /// upscaled), height from `aspect`.
    static func outputPixelSize(cropPixelWidth: CGFloat, maxWidth: Int = outputWidth,
                                aspect: CGFloat = cardAspect) -> CGSize {
        let width = max(1, min(CGFloat(maxWidth), cropPixelWidth.rounded(.down)))
        return CGSize(width: width, height: max(1, (width / aspect).rounded()))
    }

    /// The largest window of `aspect` that fits `container` with `inset`
    /// on the sides (the crop screen's layout).
    static func viewportSize(fitting container: CGSize, aspect: CGFloat = cardAspect,
                             horizontalInset: CGFloat = 16) -> CGSize {
        let width = max(1, container.width - horizontalInset * 2)
        let height = width / aspect
        if height <= container.height * 0.8 {
            return CGSize(width: width, height: height)
        }
        let limitedHeight = max(1, container.height * 0.8)
        return CGSize(width: limitedHeight * aspect, height: limitedHeight)
    }

    // MARK: - Restore

    /// Inverse of `normalizedCropRect`: the zoom / offset that show
    /// `rect` (its width decides the zoom; clamped like any gesture).
    private mutating func restore(_ rect: CGRect) {
        let widthZoom = viewportSize.width / (imageSize.width * fillScale * rect.width)
        let heightZoom = viewportSize.height / (imageSize.height * fillScale * rect.height)
        zoom = min(max(min(widthZoom, heightZoom), 1), Self.maxZoom)
        let displayed = displayedSize
        let dx = displayed.width * (0.5 - rect.minX) - viewportSize.width / 2
        let dy = displayed.height * (0.5 - rect.minY) - viewportSize.height / 2
        offset = clamped(CGSize(width: dx, height: dy))
    }
}
