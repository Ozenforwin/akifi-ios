#if DEBUG
import SwiftUI
import UIKit

/// DEBUG-only account-cover fixtures for the screenshot harness (1.6.0).
/// Compiled out of Release with the rest of `Debug/`.
///
/// `xcrun simctl launch <device> ru.akifi.app -AkifiUIHarness -spotlight_completed YES -AkifiUIHarnessCover <screen>`
///
/// | Screen | Shows |
/// |---|---|
/// | `homeBright` | Home, the first card has a bright (beach) cover |
/// | `homeDark` | Home, the first card has a dark (night city) cover — a shared account |
/// | `crop` | the crop screen over a large bright photo |
/// | `ownerSection` | account settings of the owner, scrolled to «Обложка» |
/// | `memberSection` | the same for a member of a shared account (no edit controls) |
/// | `shared` | the shared account's detail header with its cover |
///
/// Covers are served by the harness network stub
/// (`UIHarnessFixtures.reply` → `UIHarnessCovers.reply`) as generated
/// JPEGs, through the app's real download path — no network, no assets.
enum UIHarnessCoverScreen: String, CaseIterable {
    case homeBright, homeDark, crop, ownerSection, memberSection, shared

    static var requested: UIHarnessCoverScreen? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-AkifiUIHarnessCover"),
              index + 1 < arguments.count else { return nil }
        return UIHarnessCoverScreen(rawValue: arguments[index + 1])
    }
}

enum UIHarnessCovers {
    static let brightAccountId = "6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b"
    static let sharedAccountId = "7a2e3d4c-5b6a-4f70-9b8c-0d1e2f3a4b5c"
    static let brightCoverPath = "\(brightAccountId)/0b9c8d7e-6f5a-4b3c-9d2e-1f0a9b8c7d6e.jpg"
    static let darkCoverPath = "\(sharedAccountId)/1c0d9e8f-7a6b-4c5d-8e3f-2a1b0c9d8e7f.jpg"

    static var brightAccount: Account {
        Account(id: brightAccountId, userId: "demo", name: "Отпуск", icon: "🏖️", color: "#38BDF8",
                initialBalance: 184_500_00, isPrimary: UIHarnessCoverScreen.requested != .homeDark,
                currency: "rub", coverPath: brightCoverPath)
    }

    /// A shared account someone else owns: the viewer ("demo") is a member.
    static var sharedAccount: Account {
        Account(id: sharedAccountId, userId: "partner", name: "Семейный", icon: "🏠", color: "#A78BFA",
                initialBalance: 63_240_00, isPrimary: UIHarnessCoverScreen.requested == .homeDark,
                currency: "rub", coverPath: darkCoverPath)
    }

    /// The harness's account list for a cover screen: the cover accounts in
    /// front of the demo ones (installed by `UIHarness.makeAppViewModel`).
    static var accounts: [Account]? {
        guard let screen = UIHarnessCoverScreen.requested else { return nil }
        let covered = screen == .homeDark ? [sharedAccount, brightAccount] : [brightAccount, sharedAccount]
        return covered + DemoData.accounts.map { account in
            var copy = account
            copy.isPrimary = false
            return copy
        }
    }

    // MARK: - Network stub

    /// `GET /storage/v1/object/account-covers/<path>` → a generated JPEG.
    static func reply(to request: URLRequest) -> UIHarnessFixtures.Reply? {
        guard let path = request.url?.path,
              let range = path.range(of: "/storage/v1/object/\(AccountCoverPath.bucket)/") else { return nil }
        let objectPath = String(path[range.upperBound...])
        let data: Data?
        switch objectPath {
        case brightCoverPath: data = photo(.beach, size: CGSize(width: 1200, height: 632))
        case darkCoverPath: data = photo(.night, size: CGSize(width: 1200, height: 632))
        default: data = nil
        }
        guard let data else {
            return UIHarnessFixtures.Reply(status: 404, headers: ["Content-Type": "application/json"],
                                           body: Data(#"{"statusCode":"404","error":"not_found","message":"Object not found"}"#.utf8))
        }
        return UIHarnessFixtures.Reply(status: 200, headers: ["Content-Type": "image/jpeg"], body: data)
    }

    // MARK: - Generated photos

    enum Scene { case beach, night }

    static func photo(_ scene: Scene, size: CGSize) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let w = size.width, h = size.height
            switch scene {
            case .beach:
                gradient(cg, [UIColor(red: 0.53, green: 0.80, blue: 0.98, alpha: 1), UIColor(red: 0.93, green: 0.97, blue: 1, alpha: 1)],
                         from: .zero, to: CGPoint(x: 0, y: h * 0.55))
                // Sun and its glow.
                UIColor(red: 1, green: 0.98, blue: 0.86, alpha: 0.55).setFill()
                cg.fillEllipse(in: CGRect(x: w * 0.66, y: h * 0.06, width: h * 0.42, height: h * 0.42))
                UIColor(red: 1, green: 0.99, blue: 0.93, alpha: 1).setFill()
                cg.fillEllipse(in: CGRect(x: w * 0.71, y: h * 0.11, width: h * 0.32, height: h * 0.32))
                // Clouds.
                UIColor.white.withAlphaComponent(0.95).setFill()
                for (x, y, r) in [(0.12, 0.16, 0.07), (0.17, 0.13, 0.09), (0.23, 0.17, 0.07), (0.42, 0.28, 0.05), (0.47, 0.25, 0.065)] {
                    cg.fillEllipse(in: CGRect(x: w * x, y: h * y, width: w * r * 1.6, height: w * r))
                }
                // Sea.
                gradient(cg, [UIColor(red: 0.16, green: 0.68, blue: 0.78, alpha: 1), UIColor(red: 0.42, green: 0.85, blue: 0.86, alpha: 1)],
                         from: CGPoint(x: 0, y: h * 0.55), to: CGPoint(x: 0, y: h * 0.72), rect: CGRect(x: 0, y: h * 0.55, width: w, height: h * 0.17))
                // Sand.
                gradient(cg, [UIColor(red: 0.98, green: 0.91, blue: 0.75, alpha: 1), UIColor(red: 0.95, green: 0.84, blue: 0.64, alpha: 1)],
                         from: CGPoint(x: 0, y: h * 0.72), to: CGPoint(x: 0, y: h), rect: CGRect(x: 0, y: h * 0.72, width: w, height: h * 0.28))
                // Foam line.
                UIColor.white.withAlphaComponent(0.9).setFill()
                cg.fill(CGRect(x: 0, y: h * 0.715, width: w, height: h * 0.012))
            case .night:
                gradient(cg, [UIColor(red: 0.04, green: 0.05, blue: 0.16, alpha: 1), UIColor(red: 0.24, green: 0.12, blue: 0.36, alpha: 1)],
                         from: .zero, to: CGPoint(x: 0, y: h))
                // Moon.
                UIColor(red: 0.98, green: 0.95, blue: 0.82, alpha: 1).setFill()
                cg.fillEllipse(in: CGRect(x: w * 0.78, y: h * 0.10, width: h * 0.16, height: h * 0.16))
                // Stars.
                UIColor.white.withAlphaComponent(0.8).setFill()
                for i in 0..<40 {
                    let x = CGFloat((i * 73) % 100) / 100 * w
                    let y = CGFloat((i * 37) % 45) / 100 * h
                    cg.fillEllipse(in: CGRect(x: x, y: y, width: 3, height: 3))
                }
                // Skyline with lit windows.
                var x: CGFloat = 0
                var i = 0
                while x < w {
                    let width = w * (0.06 + CGFloat((i * 29) % 7) / 100)
                    let height = h * (0.25 + CGFloat((i * 41) % 30) / 100)
                    let building = CGRect(x: x, y: h - height, width: width - 4, height: height)
                    UIColor(red: 0.06, green: 0.06, blue: 0.12, alpha: 1).setFill()
                    cg.fill(building)
                    UIColor(red: 1, green: 0.82, blue: 0.45, alpha: 0.9).setFill()
                    var wy = building.minY + 12
                    var row = 0
                    while wy < building.maxY - 10 {
                        var wx = building.minX + 8
                        var column = 0
                        while wx < building.maxX - 12 {
                            if (row * 7 + column * 3 + i) % 4 != 0 {
                                cg.fill(CGRect(x: wx, y: wy, width: 7, height: 9))
                            }
                            wx += 16
                            column += 1
                        }
                        wy += 20
                        row += 1
                    }
                    x += width
                    i += 1
                }
            }
        }
        guard let cgImage = image.cgImage else { return nil }
        return AccountCoverImageProcessor.jpeg(cgImage, quality: 0.85)
    }

    private static func gradient(_ cg: CGContext, _ colors: [UIColor], from start: CGPoint, to end: CGPoint, rect: CGRect? = nil) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: colors.map(\.cgColor) as CFArray, locations: nil) else { return }
        cg.saveGState()
        if let rect { cg.clip(to: rect) }
        cg.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        cg.restoreGState()
    }
}

/// Root of a cover harness screen.
struct UIHarnessCoverScreenView: View {
    let screen: UIHarnessCoverScreen
    @Environment(AppViewModel.self) private var app
    @State private var currentAccountContext = CurrentAccountContext()

    var body: some View {
        content
            .environment(currentAccountContext)
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .homeBright, .homeDark:
            MainTabView()
        case .crop:
            if let data = UIHarnessCovers.photo(.beach, size: CGSize(width: 2400, height: 1800)),
               let cgImage = AccountCoverImageProcessor.decode(data) {
                AccountCoverCropView(
                    session: AccountCoverCropSession(source: AccountCoverSource(cgImage: cgImage), initialCrop: nil),
                    account: UIHarnessCovers.brightAccount,
                    balanceText: app.currencyManager.formatAmount(Decimal(184_500)),
                    onCancel: {},
                    onDone: { _ in }
                )
            }
        case .ownerSection:
            AccountFormView(editingAccount: UIHarnessCovers.brightAccount) {}
                .task { await scrollToCover() }
        case .memberSection:
            AccountFormView(editingAccount: UIHarnessCovers.sharedAccount) {}
                .task { await scrollToCover() }
        case .shared:
            NavigationStack {
                SharedAccountDetailView(account: UIHarnessCovers.sharedAccount)
            }
        }
    }

    /// The form opens at the top; «Обложка» sits below the icon and colour
    /// grids.
    private func scrollToCover() async {
        try? await Task.sleep(for: .seconds(1.5))
        UIHarness.scrollVisibleList(by: 560)
    }
}
#endif
