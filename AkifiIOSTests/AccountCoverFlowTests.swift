import CoreGraphics
import PhotosUI
import SwiftUI
import XCTest
@testable import AkifiIOS

/// The cover picker → crop flow (device bug 2026-11-28: the crop screen
/// flashed and vanished, nothing was uploaded). The flow lives in ONE
/// `AccountCoverFlow` per form; the section only shows rows.
@MainActor
final class AccountCoverFlowTests: XCTestCase {

    private func source() throws -> AccountCoverSource {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        return AccountCoverSource(cgImage: try XCTUnwrap(context.makeImage()))
    }

    /// A second delivery of the picker result while the crop screen is up
    /// must not replace (and so dismiss) it.
    func testAPickWhileCroppingIsIgnored() async throws {
        let flow = AccountCoverFlow()
        let session = AccountCoverCropSession(source: try source(), initialCrop: nil)
        flow.cropSession = session

        await flow.pick(PhotosPickerItem(itemIdentifier: "duplicate-delivery"))

        XCTAssertEqual(flow.cropSession, session)
        XCTAssertNil(flow.errorMessage)
        XCTAssertFalse(flow.isPreparing)
    }

    func testAPickWhilePreparingIsIgnored() async {
        let flow = AccountCoverFlow()
        flow.isPreparing = true

        await flow.pick(PhotosPickerItem(itemIdentifier: "duplicate-delivery"))

        XCTAssertNil(flow.cropSession)
        XCTAssertNil(flow.errorMessage)
        XCTAssertTrue(flow.isPreparing, "the running preparation owns the flag")
    }

    /// A navigation value: equal by identity, not by pixels.
    func testCropSessionsAreEqualByIdentity() throws {
        let image = try source()
        let a = AccountCoverCropSession(source: image, initialCrop: nil)
        let b = AccountCoverCropSession(source: image, initialCrop: nil)
        XCTAssertEqual(a, a)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(Set([a, a, b]).count, 2)
    }

    /// Device feedback 2026-11-28 («полоса выглядит супер странно»): the
    /// scrim dipped to a light floor between the two text bands — a bright
    /// stripe across a photo. Between the bands it must go monotonically
    /// from one band's opacity to the other's, and stay flat over each band.
    func testTheScrimHasNoLightStripeBetweenTheBands() {
        let tones = [
            AccountCoverTone(top: 1, bottom: 1),
            AccountCoverTone(top: 0.9, bottom: 0.2),
            AccountCoverTone(top: 0.1, bottom: 0.95),
            AccountCoverTone(top: 0.02, bottom: 0.02),
        ]
        for tone in tones {
            for increased in [false, true] {
                let scrim = AccountCoverScrim.make(for: tone, increasedContrast: increased)
                let stops = scrim.stops
                XCTAssertEqual(stops.first?.location, 0)
                XCTAssertEqual(stops.last?.location, 1)
                XCTAssertEqual(stops.map(\.location), stops.map(\.location).sorted(), "locations ascend")
                let low = min(scrim.top, scrim.bottom), high = max(scrim.top, scrim.bottom)
                for stop in stops {
                    XCTAssertGreaterThanOrEqual(stop.opacity, low - 1e-9, "never lighter than both bands (\(tone))")
                    XCTAssertLessThanOrEqual(stop.opacity, high + 1e-9)
                    if AccountCoverTone.topBand.contains(stop.location) {
                        XCTAssertEqual(stop.opacity, scrim.top, accuracy: 1e-9, "flat over the header")
                    }
                    if AccountCoverTone.bottomBand.contains(stop.location) {
                        XCTAssertEqual(stop.opacity, scrim.bottom, accuracy: 1e-9, "flat over the balance")
                    }
                }
                let opacities = stops.map(\.opacity)
                let pairs = zip(opacities, opacities.dropFirst())
                if scrim.bottom >= scrim.top {
                    XCTAssertTrue(pairs.allSatisfy { $0 <= $1 + 1e-9 }, "monotonic (\(tone))")
                } else {
                    XCTAssertTrue(pairs.allSatisfy { $0 + 1e-9 >= $1 }, "monotonic (\(tone))")
                }
            }
        }
    }

    /// A modifier on a `Section` inside a `Form` is applied to every row:
    /// the section must not observe the picker or present anything — that
    /// is `accountCoverFlow(_:account:)`, attached once to the form.
    func testTheSectionPresentsNothing() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AkifiIOS/Views/Home/AccountCoverViews.swift")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("App sources are not reachable from this test host")
        }
        let source = try String(contentsOf: file, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "struct AccountCoverSection: View {"))
        let end = try XCTUnwrap(source.range(of: "extension View {", range: start.upperBound..<source.endIndex))
        let section = source[start.lowerBound..<end.lowerBound]
        for presenter in [".onChange(", ".fullScreenCover(", ".sheet(", ".navigationDestination(",
                          ".confirmationDialog(", ".alert("] {
            XCTAssertFalse(section.contains(presenter), "AccountCoverSection must not use \(presenter)")
        }

        let form = try String(
            contentsOf: file.deletingLastPathComponent().appendingPathComponent("AccountFormView.swift"),
            encoding: .utf8
        )
        XCTAssertEqual(form.components(separatedBy: ".accountCoverFlow(").count - 1, 1,
                       "the form attaches the cover flow exactly once")
    }
}
