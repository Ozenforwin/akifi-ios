import XCTest
@testable import AkifiIOS

/// The owner's «Затемнение» (accounts.cover_dim, migration 20261128110000):
/// nil = automatic, 0…100 = lighter…darker, shared like the cover.
final class AccountCoverDimTests: XCTestCase {

    private let tones = [
        AccountCoverTone(top: 1, bottom: 1),
        AccountCoverTone(top: 0.9, bottom: 0.25),
        AccountCoverTone(top: 0.15, bottom: 0.8),
        AccountCoverTone(top: 0.03, bottom: 0.02),
    ]

    func testNilIsTheAutomaticScrim() {
        for tone in tones {
            for increased in [false, true] {
                XCTAssertEqual(AccountCoverScrim.make(for: tone, increasedContrast: increased, dim: nil),
                               AccountCoverScrim.make(for: tone, increasedContrast: increased))
            }
        }
    }

    func testDarkerAsTheSliderMoves() {
        for tone in tones {
            var previous: AccountCoverScrim?
            for dim in stride(from: 0, through: 100, by: 10) {
                let scrim = AccountCoverScrim.make(for: tone, dim: dim)
                if let previous {
                    XCTAssertGreaterThanOrEqual(scrim.top, previous.top - 1e-9)
                    XCTAssertGreaterThanOrEqual(scrim.bottom, previous.bottom - 1e-9)
                    XCTAssertGreaterThanOrEqual(scrim.uniform, previous.uniform - 1e-9)
                }
                XCTAssertLessThanOrEqual(scrim.top, AccountCoverScrim.maxOpacity + 1e-9)
                XCTAssertLessThanOrEqual(scrim.bottom, AccountCoverScrim.maxOpacity + 1e-9)
                previous = scrim
            }
            let darkest = AccountCoverScrim.make(for: tone, dim: 100)
            XCTAssertGreaterThanOrEqual(darkest.bottom, AccountCoverScrim.darkestOpacity - 1e-9)
        }
    }

    /// «Светлее» can go lighter than automatic, never below WCAG AA for
    /// large text (3 : 1) for every colour drawn on a cover.
    func testTheLightEndKeepsLargeTextReadable() {
        for tone in tones {
            let lightest = AccountCoverScrim.make(for: tone, dim: 0)
            let auto = AccountCoverScrim.make(for: tone)
            XCTAssertLessThanOrEqual(lightest.bottom, auto.bottom + 1e-9, "the light end is not darker than auto")
            for (luminance, opacity) in [(tone.top, lightest.top), (tone.bottom, lightest.bottom)] {
                let background = AccountCoverScrim.scrimmed(luminance, opacity: opacity)
                for text in AccountCoverScrim.textLuminances {
                    XCTAssertGreaterThanOrEqual(
                        AccountCoverScrim.contrastRatio(text, background), AccountCoverScrim.lightestContrast - 0.01,
                        "tone \(tone): text \(text) on \(background)"
                    )
                }
            }
        }
    }

    /// Increase Contrast wins over a light choice: never lighter than the
    /// automatic 7 : 1 scrim.
    func testIncreaseContrastNeverGoesLighterThanAutomatic() {
        for tone in tones {
            let auto = AccountCoverScrim.make(for: tone, increasedContrast: true)
            for dim in [0, 30, 70, 100] {
                let scrim = AccountCoverScrim.make(for: tone, increasedContrast: true, dim: dim)
                XCTAssertGreaterThanOrEqual(scrim.top, auto.top - 1e-9)
                XCTAssertGreaterThanOrEqual(scrim.bottom, auto.bottom - 1e-9)
            }
        }
    }

    /// While on «Авто» the slider sits where automatic is.
    func testTheAutoPositionMatchesTheAutomaticScrim() {
        for tone in tones {
            let position = AccountCoverScrim.autoDimPosition(for: tone)
            XCTAssertTrue((0...100).contains(position))
            let atPosition = AccountCoverScrim.make(for: tone, dim: position)
            let auto = AccountCoverScrim.make(for: tone)
            XCTAssertEqual(atPosition.bottom, auto.bottom, accuracy: 0.01, "tone \(tone)")
        }
    }

    // MARK: - Account decoding

    private func decodeAccount(coverDim: String?) throws -> Account {
        let extra = coverDim.map { #","cover_dim":\#($0)"# } ?? ""
        let json = ##"{"id":"a1","user_id":"u1","name":"Семейный","icon":"💵","color":"#3B82F6","initial_balance":0\##(extra)}"##
        return try JSONDecoder().decode(Account.self, from: Data(json.utf8))
    }

    func testCoverDimDecodesTolerantly() throws {
        XCTAssertEqual(try decodeAccount(coverDim: "40").coverDim, 40)
        XCTAssertNil(try decodeAccount(coverDim: nil).coverDim, "servers before 20261128110000")
        XCTAssertNil(try decodeAccount(coverDim: "null").coverDim)
        XCTAssertNil(try decodeAccount(coverDim: "150").coverDim, "out of range reads as automatic")
        XCTAssertNil(try decodeAccount(coverDim: #""dark""#).coverDim, "a wrong type never fails the row")
    }

    func testCoverDimRoundTripsThroughTheCache() throws {
        var account = try decodeAccount(coverDim: "65")
        account = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(account))
        XCTAssertEqual(account.coverDim, 65)
        let automatic = try decodeAccount(coverDim: nil)
        let json = String(decoding: try JSONEncoder().encode(automatic), as: UTF8.self)
        XCTAssertFalse(json.contains("cover_dim"), "nil is not written (account writes never send it)")
    }

    // MARK: - Store

    func testSetDimGoesToTheServer() async throws {
        let remote = FakeCoverRemote()
        let store = await AccountCoverStore(remote: remote)
        let account = try decodeAccount(coverDim: nil)
        try await store.setDim(30, for: account)
        try await store.setDim(nil, for: account)
        let calls = await remote.calls
        XCTAssertEqual(calls, [.setCoverDim(30, "a1"), .setCoverDim(nil, "a1")])
    }
}
