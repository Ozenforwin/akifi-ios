import UIKit

extension UIImage {

    /// The image shrunk so its longer edge is at most `maxEdge` PIXELS.
    ///
    /// `UIGraphicsImageRenderer(size:)` renders at the screen scale: a
    /// 4032×3024 photo "reduced" to 1600 pt came out 4800×3600 px on a 3×
    /// iPhone — bigger than the original — and receipts went to analysis at
    /// 5400 px (V5). The format here is pinned to scale 1, so `maxEdge` is
    /// the pixel size of the result. Images already small enough are
    /// returned unchanged.
    ///
    /// Drawing into a new context also drops EXIF/GPS metadata; orientation
    /// is applied, so the result is upright.
    func downscaled(toMaxEdge maxEdge: CGFloat) -> UIImage {
        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        let longest = max(pixelSize.width, pixelSize.height)
        guard longest > maxEdge, longest > 0 else { return self }
        let ratio = maxEdge / longest
        let newSize = CGSize(
            width: (pixelSize.width * ratio).rounded(),
            height: (pixelSize.height * ratio).rounded()
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
