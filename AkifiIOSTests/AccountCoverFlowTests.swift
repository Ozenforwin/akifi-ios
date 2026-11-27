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
