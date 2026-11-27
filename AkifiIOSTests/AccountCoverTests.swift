import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import AkifiIOS

/// Account covers (1.6.0): object names, decoding, who may edit, the crop
/// math, the upload pixels and the scrim's contrast guarantee.
final class AccountCoverTests: XCTestCase {

    private static let accountId = "6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b"
    private static let objectId = UUID(uuidString: "0B9C8D7E-6F5A-4B3C-9D2E-1F0A9B8C7D6E")!

    // MARK: - Path builder / validation

    func test_path_make_isLowercaseAccountFolderAndUUIDJpg() {
        let path = AccountCoverPath.make(accountId: Self.accountId.uppercased(), objectId: Self.objectId)
        XCTAssertEqual(path, "6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b/0b9c8d7e-6f5a-4b3c-9d2e-1f0a9b8c7d6e.jpg")
        XCTAssertEqual(path.count, 77, "the length the server's CHECK requires")
        XCTAssertTrue(AccountCoverPath.isValid(path, accountId: Self.accountId))
    }

    func test_path_make_isNewEveryTime() {
        XCTAssertNotEqual(AccountCoverPath.make(accountId: Self.accountId), AccountCoverPath.make(accountId: Self.accountId))
    }

    func test_path_validation_mirrorsTheServerShape() {
        let good = AccountCoverPath.make(accountId: Self.accountId, objectId: Self.objectId)
        XCTAssertTrue(AccountCoverPath.isValid(good))
        let bad = [
            good.uppercased(),
            good.replacingOccurrences(of: ".jpg", with: ".png"),
            "\(Self.accountId)/cover.jpg",
            "\(Self.accountId)/../\(Self.objectId.uuidString.lowercased()).jpg",
            "x/\(good)",
            "/\(good)",
            "\(Self.accountId)\(Self.objectId.uuidString.lowercased()).jpg",
            "",
            "demo-acc-1/\(Self.objectId.uuidString.lowercased()).jpg",
        ]
        for path in bad {
            XCTAssertFalse(AccountCoverPath.isValid(path), path)
        }
        XCTAssertFalse(AccountCoverPath.isValid(nil))
        XCTAssertFalse(AccountCoverPath.isValid(good, accountId: "7a2e3d4c-5b6a-4f70-9b8c-0d1e2f3a4b5c"),
                       "another account's folder")
    }

    func test_path_accountId_andCacheFileName() {
        let good = AccountCoverPath.make(accountId: Self.accountId, objectId: Self.objectId)
        XCTAssertEqual(AccountCoverPath.accountId(of: good), Self.accountId)
        XCTAssertEqual(AccountCoverPath.cacheFileName(for: good),
                       "6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b_0b9c8d7e-6f5a-4b3c-9d2e-1f0a9b8c7d6e.jpg")
        XCTAssertNil(AccountCoverPath.cacheFileName(for: "../../Library/Preferences/x.jpg"),
                     "a server value never steers a write outside the cache")
        XCTAssertNil(AccountCoverPath.accountId(of: "nope"))
    }

    // MARK: - Decoding

    private func decodeAccount(_ extra: String) throws -> Account {
        let json = """
        {"id":"\(Self.accountId)","user_id":"u1","name":"Карта","icon":"💳","color":"#3B82F6",
         "initial_balance":100,"currency":"rub"\(extra)}
        """
        return try JSONDecoder().decode(Account.self, from: Data(json.utf8))
    }

    func test_decoding_withoutCoverPath_olderServer() throws {
        XCTAssertNil(try decodeAccount("").coverPath)
    }

    func test_decoding_withCoverPath() throws {
        let path = AccountCoverPath.make(accountId: Self.accountId, objectId: Self.objectId)
        XCTAssertEqual(try decodeAccount(#","cover_path":"\#(path)""#).coverPath, path)
    }

    func test_decoding_nullOrWrongType_neverFailsTheRow() throws {
        XCTAssertNil(try decodeAccount(#","cover_path":null"#).coverPath)
        let odd = try decodeAccount(#","cover_path":42"#)
        XCTAssertNil(odd.coverPath)
        XCTAssertEqual(odd.name, "Карта", "the rest of the account still decodes")
    }

    /// The disk cache stores what `encode` writes: the cover survives a
    /// relaunch, and a cache written before 1.6 (no key) still decodes.
    func test_encodeDecode_roundTripKeepsTheCover() throws {
        let path = AccountCoverPath.make(accountId: Self.accountId, objectId: Self.objectId)
        let account = Account(id: Self.accountId, userId: "u1", name: "Карта", icon: "💳", color: "#3B82F6",
                              initialBalance: 100_00, coverPath: path)
        let decoded = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(account))
        XCTAssertEqual(decoded.coverPath, path)
        XCTAssertEqual(decoded.initialBalance, 100_00)

        let noCover = Account(id: "a", userId: "u1", name: "Н", icon: "💳", color: "#000000", initialBalance: 0)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(noCover)) as? [String: Any])
        XCTAssertNil(json["cover_path"], "no cover → no key, like the server's older rows")
    }

    // MARK: - Owner-only editing

    private func account(owner: String, type: AccountType = .checking) -> Account {
        Account(id: Self.accountId, userId: owner, name: "Семейный", icon: "🏠", color: "#A78BFA",
                initialBalance: 0, accountType: type)
    }

    func test_policy_ownerEdits_membersOnlySee() {
        XCTAssertTrue(AccountCoverPolicy.canEdit(account(owner: "owner-1"), viewerId: "owner-1"))
        XCTAssertTrue(AccountCoverPolicy.canEdit(account(owner: "OWNER-1"), viewerId: "owner-1"), "ids compare case-insensitively")
        XCTAssertFalse(AccountCoverPolicy.canEdit(account(owner: "owner-1"), viewerId: "member-2"),
                       "an editor or viewer of a shared account sees no edit controls")
        XCTAssertFalse(AccountCoverPolicy.canEdit(account(owner: "owner-1"), viewerId: nil))
        XCTAssertFalse(AccountCoverPolicy.canEdit(account(owner: "owner-1"), viewerId: ""))
    }

    func test_policy_debtAccountsHaveNoCover() {
        let debt = account(owner: "owner-1", type: .debt)
        XCTAssertFalse(AccountCoverPolicy.supportsCover(debt))
        XCTAssertFalse(AccountCoverPolicy.canEdit(debt, viewerId: "owner-1"))
        XCTAssertTrue(AccountCoverPolicy.supportsCover(account(owner: "owner-1", type: .deposit)))
    }

    // MARK: - Crop math

    private let viewport = CGSize(width: 361, height: 190)

    private func assertRect(_ a: CGRect, _ b: CGRect, accuracy: CGFloat = 0.0005, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.minX, b.minX, accuracy: accuracy, "x", file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: accuracy, "y", file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: accuracy, "width", file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: accuracy, "height", file: file, line: line)
    }

    func test_crop_startsCentred_fillingTheWindow_wideImage() {
        let crop = AccountCoverCrop(imageSize: CGSize(width: 4000, height: 1000), viewportSize: viewport)
        XCTAssertEqual(crop.zoom, 1)
        // Height decides the fill: the window shows the full height.
        let rect = crop.normalizedCropRect
        XCTAssertEqual(rect.height, 1, accuracy: 0.0001)
        XCTAssertEqual(rect.width, (361.0 / 190.0) / 4.0, accuracy: 0.0001)
        XCTAssertEqual(rect.midX, 0.5, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(crop.displayedSize.width, viewport.width)
        XCTAssertGreaterThanOrEqual(crop.displayedSize.height, viewport.height - 0.001)
    }

    func test_crop_startsCentred_tallPortraitPhoto() {
        let crop = AccountCoverCrop(imageSize: CGSize(width: 3024, height: 4032), viewportSize: viewport)
        let rect = crop.normalizedCropRect
        XCTAssertEqual(rect.width, 1, accuracy: 0.0001, "width decides the fill")
        XCTAssertEqual(rect.midY, 0.5, accuracy: 0.0001)
        // The crop keeps the window's aspect in pixels.
        XCTAssertEqual((rect.width * 3024) / (rect.height * 4032), 361.0 / 190.0, accuracy: 0.001)
    }

    func test_crop_panIsClamped_soTheWindowIsAlwaysFilled() {
        var crop = AccountCoverCrop(imageSize: CGSize(width: 3024, height: 4032), viewportSize: viewport)
        crop.setOffset(CGSize(width: 500, height: 10_000))
        XCTAssertEqual(crop.offset.width, 0, "no horizontal room at zoom 1")
        XCTAssertEqual(crop.offset.height, crop.maxOffset.height)
        let rect = crop.normalizedCropRect
        XCTAssertEqual(rect.minY, 0, accuracy: 0.0001, "dragged down to the photo's top edge, not past it")

        crop.setOffset(CGSize(width: 0, height: -10_000))
        XCTAssertEqual(crop.normalizedCropRect.maxY, 1, accuracy: 0.0001)
    }

    func test_crop_zoomIsClamped() {
        var crop = AccountCoverCrop(imageSize: CGSize(width: 2000, height: 1000), viewportSize: viewport)
        crop.setZoom(0.2)
        XCTAssertEqual(crop.zoom, 1, "never smaller than the window")
        crop.setZoom(100)
        XCTAssertEqual(crop.zoom, AccountCoverCrop.maxZoom)
        crop.setZoom(.nan)
        XCTAssertEqual(crop.zoom, 1)
    }

    func test_crop_zoomHalvesTheWindow_andKeepsTheCentrePoint() {
        var crop = AccountCoverCrop(imageSize: CGSize(width: 4000, height: 3000), viewportSize: viewport)
        crop.setZoom(2)
        crop.setOffset(CGSize(width: 100, height: -40))
        let before = crop.normalizedCropRect
        crop.setZoom(4)
        let after = crop.normalizedCropRect
        XCTAssertEqual(after.width, before.width / 2, accuracy: 0.0001)
        XCTAssertEqual(after.midX, before.midX, accuracy: 0.0001, "the point under the window's centre stays")
        XCTAssertEqual(after.midY, before.midY, accuracy: 0.0001)
    }

    func test_crop_zoomOut_reclampsTheOffset() {
        var crop = AccountCoverCrop(imageSize: CGSize(width: 4000, height: 3000), viewportSize: viewport)
        crop.setZoom(3)
        crop.setOffset(CGSize(width: 10_000, height: 10_000))
        crop.setZoom(1)
        XCTAssertEqual(crop.offset.width, crop.maxOffset.width)
        XCTAssertEqual(crop.offset.height, crop.maxOffset.height)
        let rect = crop.normalizedCropRect
        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
        XCTAssertLessThanOrEqual(rect.maxX, 1.0000001)
        XCTAssertLessThanOrEqual(rect.maxY, 1.0000001)
    }

    /// «Изменить область» reopens exactly the saved crop, also in a window
    /// of another size (another iPhone).
    func test_crop_restoresAPreviousResult() {
        var crop = AccountCoverCrop(imageSize: CGSize(width: 4032, height: 3024), viewportSize: viewport)
        crop.setZoom(2.4)
        crop.setOffset(CGSize(width: -120, height: 35))
        let saved = crop.normalizedCropRect

        let reopened = AccountCoverCrop(imageSize: CGSize(width: 4032, height: 3024), viewportSize: viewport, normalizedCrop: saved)
        assertRect(reopened.normalizedCropRect, saved)

        let otherPhone = CGSize(width: 398, height: 398 / AccountCoverCrop.cardAspect)
        let cardAspectSaved: CGRect = {
            var c = AccountCoverCrop(imageSize: CGSize(width: 4032, height: 3024),
                                     viewportSize: CGSize(width: 361, height: 361 / AccountCoverCrop.cardAspect))
            c.setZoom(2)
            c.setOffset(CGSize(width: 50, height: -20))
            return c.normalizedCropRect
        }()
        let bigger = AccountCoverCrop(imageSize: CGSize(width: 4032, height: 3024), viewportSize: otherPhone, normalizedCrop: cardAspectSaved)
        assertRect(bigger.normalizedCropRect, cardAspectSaved, accuracy: 0.002)
    }

    func test_crop_pixelRect_isIntegralAndInside() {
        let rect = AccountCoverCrop.pixelRect(for: CGRect(x: 0.333, y: 0.1, width: 0.5, height: 0.7),
                                              pixelSize: CGSize(width: 1001, height: 777))
        XCTAssertEqual(rect, rect.integral)
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1001, height: 777).contains(rect))
        let overflowing = AccountCoverCrop.pixelRect(for: CGRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5),
                                                     pixelSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(overflowing.maxX, 100)
        XCTAssertEqual(overflowing.maxY, 100)
    }

    func test_crop_outputSize_neverUpscales() {
        // Bank-card proportions (85.60 × 53.98): 1200 × 757, 800 × 504.
        XCTAssertEqual(AccountCoverCrop.outputPixelSize(cropPixelWidth: 3000), CGSize(width: 1200, height: 757))
        XCTAssertEqual(AccountCoverCrop.outputPixelSize(cropPixelWidth: 800.7), CGSize(width: 800, height: 504))
    }

    func test_crop_viewportFitsTheScreen() {
        let size = AccountCoverCrop.viewportSize(fitting: CGSize(width: 393, height: 700))
        XCTAssertEqual(size.width, 361)
        XCTAssertEqual(size.width / size.height, AccountCoverCrop.cardAspect, accuracy: 0.0001)
        let landscape = AccountCoverCrop.viewportSize(fitting: CGSize(width: 900, height: 300))
        XCTAssertLessThanOrEqual(landscape.height, 240.0001)
        XCTAssertEqual(landscape.width / landscape.height, AccountCoverCrop.cardAspect, accuracy: 0.0001)
    }

    // MARK: - Upload pixels

    /// A JPEG with EXIF orientation 6 (rotated 90°) and a GPS position —
    /// what an iPhone photo looks like.
    private func cameraJPEG(width: Int = 400, height: Int = 300) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 55.7558, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 37.6173, kCGImagePropertyGPSLongitudeRef: "E",
            ],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:28 10:00:00"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func properties(of data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    func test_decode_appliesTheOrientation() throws {
        let photo = try cameraJPEG()
        XCTAssertNotNil(try properties(of: photo)[kCGImagePropertyGPSDictionary], "fixture carries GPS")
        let image = try XCTUnwrap(AccountCoverImageProcessor.decode(photo))
        XCTAssertEqual(image.width, 300, "orientation 6: upright = rotated")
        XCTAssertEqual(image.height, 400)
        let small = try XCTUnwrap(AccountCoverImageProcessor.decode(photo, maxPixel: 100))
        XCTAssertEqual(max(small.width, small.height), 100)
        XCTAssertNil(AccountCoverImageProcessor.decode(Data("not an image".utf8)))
    }

    func test_upload_hasNoLocationOrCameraMetadata_andTheCardSize() throws {
        let image = try XCTUnwrap(AccountCoverImageProcessor.decode(try cameraJPEG(width: 3000, height: 2000)))
        // Upright the photo is 2000 × 3000; a crop 1600 px wide at the card's ratio.
        let jpeg = try XCTUnwrap(AccountCoverImageProcessor.coverJPEG(
            from: image, crop: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8 * 2000 / AccountCoverCrop.cardAspect / 3000)))
        let props = try properties(of: jpeg)
        XCTAssertNil(props[kCGImagePropertyGPSDictionary], "no location")
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal], "no capture date")
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFModel], "no camera")
        let orientation = props[kCGImagePropertyOrientation] as? Int
        XCTAssertTrue(orientation == nil || orientation == 1, "pixels are upright, no rotation flag")
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 1200)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 757)
        XCTAssertLessThanOrEqual(jpeg.count, AccountCoverImageProcessor.maxUploadBytes)
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8], "a JPEG")
    }

    func test_render_cutsTheRequestedRegion() throws {
        // Left half red, right half blue; the crop takes the right half.
        let context = try XCTUnwrap(CGContext(data: nil, width: 2000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 1000))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 1000, y: 0, width: 1000, height: 1000))
        let image = try XCTUnwrap(context.makeImage())

        let rendered = try XCTUnwrap(AccountCoverImageProcessor.render(
            image, crop: CGRect(x: 0.5, y: 0.2, width: 0.5, height: 0.5 * 2 / AccountCoverCrop.cardAspect)))
        XCTAssertEqual(rendered.width, 1000, "a 1000 px crop is not upscaled to 1200")
        let tone = AccountCoverImageProcessor.tone(of: rendered)
        let blue = AccountCoverScrim.relativeLuminance(hex: "#0000FF")
        XCTAssertEqual(tone.overall, blue, accuracy: 0.02, "only blue made it into the crop")
    }

    // MARK: - Tone and scrim

    func test_tone_measuresEachTextBand() throws {
        // White top half, black bottom half.
        let context = try XCTUnwrap(CGContext(data: nil, width: 380, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 380, height: 200))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 100, width: 380, height: 100))   // y up: the TOP half
        let tone = AccountCoverImageProcessor.tone(of: try XCTUnwrap(context.makeImage()))
        XCTAssertEqual(tone.top, 1, accuracy: 0.01)
        XCTAssertEqual(tone.bottom, 0, accuracy: 0.01)
        XCTAssertEqual(tone.overall, 1, accuracy: 0.01)
    }

    /// A night photo: dark, but with small lit windows where the balance
    /// sits. They are what the text has to beat — not the dark average.
    func test_tone_smallBrightDetailsCount() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 632, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.04, green: 0.05, blue: 0.12, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 632))
        context.setFillColor(red: 1, green: 0.82, blue: 0.45, alpha: 1)
        for x in stride(from: 10, to: 1200, by: 40) {
            for y in stride(from: 10, to: 260, by: 40) {   // CG y up: the lower part
                context.fill(CGRect(x: x, y: y, width: 9, height: 11))
            }
        }
        let tone = AccountCoverImageProcessor.tone(of: try XCTUnwrap(context.makeImage()))
        XCTAssertLessThan(tone.top, 0.05, "the sky is dark")
        XCTAssertGreaterThan(tone.bottom, 0.4, "lit windows under the balance are measured, not averaged away")
        let scrim = AccountCoverScrim.make(for: tone)
        XCTAssertGreaterThan(scrim.bottom, scrim.top)
    }

    /// The guarantee: for any photo brightness, every colour the card draws
    /// on a cover reaches 4.5 : 1 (7 : 1 with Increase Contrast) in its band.
    func test_scrim_keepsEveryCoverColourLegible_onAnyPhoto() {
        for increased in [false, true] {
            let target = increased ? AccountCoverScrim.increasedContrast : AccountCoverScrim.normalContrast
            for step in 0...50 {
                let luminance = Double(step) / 50
                let scrim = AccountCoverScrim.make(
                    for: AccountCoverTone(top: luminance, bottom: luminance), increasedContrast: increased)
                for opacity in [scrim.top, scrim.bottom, scrim.uniform] {
                    let background = AccountCoverScrim.scrimmed(luminance, opacity: opacity)
                    for text in AccountCoverScrim.textLuminances {
                        XCTAssertGreaterThanOrEqual(
                            AccountCoverScrim.contrastRatio(text, background), target,
                            "photo L=\(luminance), scrim \(opacity), increased \(increased)")
                    }
                }
            }
        }
    }

    func test_scrim_darkPhotoGetsOnlyTheFloor_brightPhotoMore() {
        let dark = AccountCoverScrim.make(for: AccountCoverTone(top: 0.02, bottom: 0.03))
        XCTAssertEqual(dark.top, AccountCoverScrim.floor.top)
        XCTAssertEqual(dark.bottom, AccountCoverScrim.floor.bottom)
        let bright = AccountCoverScrim.make(for: AccountCoverTone(top: 1, bottom: 1))
        XCTAssertGreaterThan(bright.top, 0.5)
        XCTAssertLessThanOrEqual(bright.bottom, AccountCoverScrim.maxOpacity)
        XCTAssertEqual(AccountCoverScrim.make(for: .unknown), bright, "until measured: assume the brightest photo")
        let mixed = AccountCoverScrim.make(for: AccountCoverTone(top: 0.9, bottom: 0.05))
        XCTAssertGreaterThan(mixed.top, mixed.bottom, "each band gets what its own part of the photo needs")
        XCTAssertGreaterThanOrEqual(mixed.uniform, mixed.top)
    }

    /// The plain income / expense colours would fail on the scrim — the
    /// cover palette uses lighter ones of the same hue.
    func test_coverColours_areLighterThanTheSemanticOnes() {
        XCTAssertGreaterThan(AccountCoverScrim.relativeLuminance(hex: AccountCoverScrim.incomeHex),
                             AccountCoverScrim.relativeLuminance(hex: "#10B981"))
        XCTAssertGreaterThan(AccountCoverScrim.relativeLuminance(hex: AccountCoverScrim.expenseHex),
                             AccountCoverScrim.relativeLuminance(hex: "#F43F5E"))
        XCTAssertEqual(AccountCoverScrim.relativeLuminance(hex: "#FFFFFF"), 1, accuracy: 0.0001)
        XCTAssertEqual(AccountCoverScrim.contrastRatio(1, 0), 21, accuracy: 0.0001)
    }
}
