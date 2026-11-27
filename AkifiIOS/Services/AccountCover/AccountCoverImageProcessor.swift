import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Pixels of an account cover: decode the picked photo, cut the crop,
/// encode the upload. Pure and thread-agnostic — run it off the main actor.
///
/// Privacy: the upload is a NEW bitmap encoded with ImageIO and no
/// properties, so nothing of the original file — EXIF, GPS location,
/// maker notes, the camera — reaches the server (the members of a shared
/// account download it).
enum AccountCoverImageProcessor {
    /// Longest edge of the decoded working copy the crop screen shows:
    /// sharp enough for a 5× zoom of a 1200 px cover, small enough to stay
    /// light in memory (a 48 MP photo would be ~190 MB decoded).
    static let workingMaxPixel = 3600
    /// JPEG quality of the upload.
    static let jpegQuality: CGFloat = 0.8
    /// The bucket's `file_size_limit` (migration 20261128100000).
    static let maxUploadBytes = 2 * 1024 * 1024

    /// The photo upright (EXIF orientation applied), longest edge at most
    /// `maxPixel`. Nil when `data` isn't an image.
    static func decode(_ data: Data, maxPixel: Int = workingMaxPixel) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The crop `normalized` (unit space, origin top-left) of `image`,
    /// scaled to `AccountCoverCrop.outputPixelSize`, on an opaque sRGB
    /// bitmap.
    static func render(_ image: CGImage, crop normalized: CGRect,
                       maxWidth: Int = AccountCoverCrop.outputWidth,
                       aspect: CGFloat = AccountCoverCrop.cardAspect) -> CGImage? {
        let pixelSize = CGSize(width: image.width, height: image.height)
        let cropRect = AccountCoverCrop.pixelRect(for: normalized, pixelSize: pixelSize)
        guard let cropped = image.cropping(to: cropRect) else { return nil }
        let output = AccountCoverCrop.outputPixelSize(cropPixelWidth: cropRect.width, maxWidth: maxWidth, aspect: aspect)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: Int(output.width), height: Int(output.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        // The crop has the card's ratio up to a pixel of rounding; filling
        // the output rect absorbs it.
        context.draw(cropped, in: CGRect(origin: .zero, size: output))
        return context.makeImage()
    }

    /// JPEG with no metadata at all (no EXIF / GPS / TIFF dictionaries).
    static func jpeg(_ image: CGImage, quality: CGFloat = jpegQuality) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let properties = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// The brightest spot of each text band of `crop` (unit space) of
    /// `image` — what `AccountCoverScrim` has to darken. Measured on a
    /// 160 × 84 px copy: a sample is ≈2 pt of the card, about a glyph
    /// stroke — fine enough that small bright details under the text (lit
    /// windows, glints) count instead of being averaged away.
    static func tone(of image: CGImage, crop normalized: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> AccountCoverTone {
        let width = 160, height = 84
        let pixelRect = AccountCoverCrop.pixelRect(for: normalized, pixelSize: CGSize(width: image.width, height: image.height))
        guard let cropped = image.cropping(to: pixelRect),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return .unknown }
        context.interpolationQuality = .medium
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return .unknown }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        var top = 0.0, bottom = 0.0, overall = 0.0
        for row in 0..<height {
            // Memory row 0 is the top of the image.
            let y = (Double(row) + 0.5) / Double(height)
            let inTop = AccountCoverTone.topBand.contains(y)
            let inBottom = AccountCoverTone.bottomBand.contains(y)
            for column in 0..<width {
                let i = (row * width + column) * 4
                let luminance = AccountCoverScrim.relativeLuminance(
                    r: Double(pixels[i]) / 255, g: Double(pixels[i + 1]) / 255, b: Double(pixels[i + 2]) / 255
                )
                overall = max(overall, luminance)
                if inTop { top = max(top, luminance) }
                if inBottom { bottom = max(bottom, luminance) }
            }
        }
        return AccountCoverTone(top: top, bottom: bottom, overall: overall)
    }

    /// A downloaded / cached cover, decoded for display, with its tone.
    static func coverImage(from data: Data) -> AccountCoverImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let image = UIImage(cgImage: cgImage)
        return AccountCoverImage(image: image.preparingForDisplay() ?? image, tone: tone(of: cgImage))
    }

    /// The upload for a crop of `image`: rendered, encoded, and re-encoded
    /// at a lower quality in the unlikely case it exceeds the bucket's
    /// size limit.
    static func coverJPEG(from image: CGImage, crop normalized: CGRect) -> Data? {
        guard let rendered = render(image, crop: normalized) else { return nil }
        for quality in [jpegQuality, 0.65, 0.5, 0.35] {
            if let data = jpeg(rendered, quality: quality), data.count <= maxUploadBytes {
                return data
            }
        }
        return nil
    }
}
