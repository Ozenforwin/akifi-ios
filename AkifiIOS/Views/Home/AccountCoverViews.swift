import PhotosUI
import SwiftUI

// Account covers (1.6.0) — the screens: the «Обложка» section of the
// account settings and the crop screen. The photo, its legibility scrim
// and the light palette live in `DesignSystem/AccountCoverBackdrop.swift`;
// rules in `.claude/design/liquid-glass.md` §11.

// MARK: - Card preview (section row, crop window)

/// A compact rendition of the Home card's text — icon tile, name,
/// balance — in the cover palette, for the «Обложка» preview and the crop
/// screen's window.
struct AccountCoverCardText: View {
    let account: Account
    let balanceText: String
    var compact = false

    @ScaledMetric(relativeTo: .title3) private var iconTileSize: CGFloat = 40

    var body: some View {
        let palette = AccountCardPalette.cover
        VStack(alignment: .leading, spacing: compact ? 4 : 12) {
            HStack(spacing: 12) {
                Text(account.icon)
                    .font(compact ? .body : .title3)
                    .frame(width: compact ? iconTileSize * 0.75 : iconTileSize,
                           height: compact ? iconTileSize * 0.75 : iconTileSize)
                    .background(palette.iconTileFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(account.name)
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            Text(verbatim: balanceText)
                .font(compact ? .title2.weight(.semibold) : .largeTitle.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .foregroundStyle(palette.primary)
        .accessibilityHidden(true)
    }
}

// MARK: - «Обложка» section (account settings)

/// State and actions of the cover flow of ONE account form — owned by the
/// form, shared by the section (rows) and `accountCoverFlow(_:account:)`
/// (the picker result, the crop screen, the remove confirmation), which is
/// attached once, to the form.
///
/// Why not on the section: a modifier on a `Section` inside a `Form` is
/// applied to every row of it. The picker's `onChange` then ran once per
/// row and each run presented its own crop screen — on device the crop
/// screen flashed and vanished, nothing was uploaded (2026-11-28).
@Observable @MainActor
final class AccountCoverFlow {
    var pickerItem: PhotosPickerItem?
    var cropSession: AccountCoverCropSession?
    var isPreparing = false
    var isApplying = false
    var errorMessage: String?
    var showRemoveConfirmation = false

    init() {}

    var isWorking: Bool { isPreparing || isApplying }

    /// The picked photo → the crop screen. A second delivery of the same
    /// pick (or a pick while one is being prepared / cropped) is ignored.
    func pick(_ item: PhotosPickerItem) async {
        guard !isPreparing, cropSession == nil else { return }
        errorMessage = nil
        isPreparing = true
        defer { isPreparing = false }
        let data: Data?
        do {
            data = try await item.loadTransferable(type: Data.self)
        } catch {
            AppLogger.data.warning("Account cover: loading the picked photo failed: \(error.localizedDescription)")
            data = nil
        }
        guard let data, let source = await AccountCoverSource.decode(data) else {
            errorMessage = AccountCoverErrorMessage.text(for: AccountCoverError.unreadableImage)
            return
        }
        cropSession = AccountCoverCropSession(source: source, initialCrop: nil)
    }

    /// «Изменить область»: the original photo when this device chose it
    /// (zoom out again), else the cover itself (zoom in further).
    func editArea(account: Account, covers: AccountCoverStore) async {
        guard !isPreparing, cropSession == nil else { return }
        errorMessage = nil
        isPreparing = true
        defer { isPreparing = false }
        if let original = await covers.original(for: account),
           let source = await AccountCoverSource.decode(original.jpeg) {
            cropSession = AccountCoverCropSession(source: source, initialCrop: original.crop)
            return
        }
        let cover: AccountCoverImage?
        if let cached = covers.image(for: account.coverPath) {
            cover = cached
        } else {
            cover = await covers.load(account.coverPath)
        }
        guard let cgImage = cover?.image.cgImage else {
            errorMessage = String(localized: "account.cover.error.notLoaded")
            return
        }
        cropSession = AccountCoverCropSession(source: AccountCoverSource(cgImage: cgImage), initialCrop: nil)
    }

    func apply(_ source: AccountCoverSource, crop: CGRect, account: Account, app: AppViewModel) async {
        errorMessage = nil
        isApplying = true
        defer { isApplying = false }
        let encoded = await Task.detached(priority: .userInitiated) { () -> (cover: Data?, original: Data?) in
            (AccountCoverImageProcessor.coverJPEG(from: source.cgImage, crop: crop),
             AccountCoverImageProcessor.jpeg(source.cgImage, quality: 0.9))
        }.value
        guard let jpeg = encoded.cover else {
            errorMessage = AccountCoverErrorMessage.text(for: AccountCoverError.encodingFailed)
            return
        }
        do {
            let path = try await app.accountCovers.setCover(jpeg, for: account)
            app.dataStore.setCoverPath(path, forAccountId: account.id)
            if let original = encoded.original {
                await app.accountCovers.saveOriginal(original, crop: crop, coverPath: path)
            }
            HapticManager.success()
        } catch {
            AppLogger.data.warning("Account cover: saving failed: \(error.localizedDescription)")
            errorMessage = AccountCoverErrorMessage.text(for: error)
        }
    }

    func remove(account: Account, app: AppViewModel) async {
        errorMessage = nil
        do {
            try await app.accountCovers.removeCover(of: account)
            app.dataStore.setCoverPath(nil, forAccountId: account.id)
        } catch {
            AppLogger.data.warning("Account cover: removing failed: \(error.localizedDescription)")
            errorMessage = AccountCoverErrorMessage.text(for: error)
        }
    }

    /// The balance line of the card preview / crop window.
    static func balanceText(for account: Account, app: AppViewModel) -> String {
        let balance = app.dataStore.balance(for: account)
        let fmt = app.currencyManager
        return balance < 0 ? "-\(fmt.formatAmount(balance.displayAmount))" : fmt.formatAmount(balance.displayAmount)
    }
}

/// The «Обложка» section of the account form — rows only (see
/// `AccountCoverFlow` for why nothing is presented from here). The owner
/// picks a photo (system picker, no library permission), crops it, changes
/// the area or removes it — each applies at once, like the sharing sheet
/// next to it. Members of a shared account see the cover and who may
/// change it.
struct AccountCoverSection: View {
    let account: Account
    @Bindable var flow: AccountCoverFlow

    @Environment(AppViewModel.self) private var appViewModel

    private var covers: AccountCoverStore { appViewModel.accountCovers }
    private var dataStore: DataStore { appViewModel.dataStore }

    /// The account as it is now (the form holds the snapshot it opened with).
    private var liveAccount: Account {
        dataStore.accounts.first { $0.id == account.id } ?? account
    }

    private var canEdit: Bool {
        AccountCoverPolicy.canEdit(liveAccount, viewerId: dataStore.profile?.id)
    }

    private var hasCover: Bool { liveAccount.coverPath != nil }

    private var isBusy: Bool {
        flow.isWorking || covers.busyAccountIds.contains(account.id)
    }

    var body: some View {
        Section {
            preview
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                // On the one row (on the section it would run per row).
                .task(id: liveAccount.coverPath) {
                    await covers.load(liveAccount.coverPath)
                }

            if canEdit {
                // Out-of-process picker: no photo-library permission. Images
                // only; HEIC is fine (ImageIO decodes it), so no transcoding.
                let pickTitle = String(localized: hasCover ? "account.cover.replace" : "account.cover.choose")
                PhotosPicker(selection: $flow.pickerItem, matching: .images, preferredItemEncoding: .current) {
                    Label(pickTitle, systemImage: "photo.on.rectangle")
                }
                .disabled(isBusy)

                if hasCover {
                    Button {
                        let account = liveAccount
                        Task { await flow.editArea(account: account, covers: covers) }
                    } label: {
                        Label(String(localized: "account.cover.editArea"), systemImage: "crop")
                    }
                    .disabled(isBusy)

                    Button(role: .destructive) {
                        flow.showRemoveConfirmation = true
                    } label: {
                        // The symbol in the same red as the title (a Form row
                        // paints a Label's icon with the tint otherwise).
                        Label {
                            Text(String(localized: "account.cover.remove"))
                        } icon: {
                            Image(systemName: "trash")
                                .foregroundStyle(Color.red)
                        }
                    }
                    .disabled(isBusy)
                }
            }

            if let errorMessage = flow.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(Color.expense)
            }
        } header: {
            Text(String(localized: "account.cover.section"))
        } footer: {
            Text(String(localized: canEdit ? "account.cover.footer.owner" : "account.cover.footer.member"))
        }
    }

    // MARK: Preview

    private var preview: some View {
        let shape = RoundedRectangle(cornerRadius: CardStyle.Size.compact.cornerRadius, style: .continuous)
        let cover = covers.image(for: liveAccount.coverPath)
        return ZStack {
            if let cover {
                AccountCoverBackdrop(cover: cover)
                AccountCoverCardText(
                    account: liveAccount,
                    balanceText: AccountCoverFlow.balanceText(for: liveAccount, app: appViewModel),
                    compact: true
                )
                .padding(12)
            } else {
                shape.fill(Color(hex: liveAccount.color).opacity(0.16))
                VStack(spacing: 6) {
                    Image(systemName: hasCover ? "photo" : "photo.badge.plus")
                        .font(.title2)
                        .foregroundStyle(Color(hex: liveAccount.color))
                    Text(String(localized: hasCover ? "account.cover.loading" : "account.cover.none"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if isBusy {
                Color.black.opacity(0.35)
                ProgressView()
                    .tint(.white)
                    .controlSize(.large)
            }
        }
        .aspectRatio(AccountCoverCrop.cardAspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "account.cover.section"))
        .accessibilityValue(String(localized: isBusy
                                   ? "account.cover.a11y.saving"
                                   : (hasCover ? "account.cover.a11y.set" : "account.cover.none")))
    }
}

extension View {
    /// The cover flow's picker handling, crop screen and remove
    /// confirmation — attach ONCE, to the account form inside its
    /// `NavigationStack` (see `AccountCoverFlow`). The crop screen is
    /// PUSHED on the form's stack: a push needs no free presentation slot,
    /// so it can't be dropped while the photo picker sheet is still
    /// animating away.
    func accountCoverFlow(_ flow: AccountCoverFlow, account: Account?) -> some View {
        modifier(AccountCoverFlowModifier(flow: flow, account: account))
    }
}

private struct AccountCoverFlowModifier: ViewModifier {
    @Bindable var flow: AccountCoverFlow
    let account: Account?

    @Environment(AppViewModel.self) private var appViewModel

    /// The account as it is now (the form holds the snapshot it opened with).
    private var liveAccount: Account? {
        guard let account else { return nil }
        return appViewModel.dataStore.accounts.first { $0.id == account.id } ?? account
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: flow.pickerItem) { _, item in
                guard let item else { return }
                flow.pickerItem = nil
                Task { await flow.pick(item) }
            }
            .navigationDestination(item: $flow.cropSession) { session in
                if let acc = liveAccount {
                    AccountCoverCropView(
                        session: session,
                        account: acc,
                        balanceText: AccountCoverFlow.balanceText(for: acc, app: appViewModel),
                        style: .pushed,
                        onCancel: { flow.cropSession = nil },
                        onDone: { crop in
                            flow.cropSession = nil
                            let target = liveAccount ?? acc
                            Task { await flow.apply(session.source, crop: crop, account: target, app: appViewModel) }
                        }
                    )
                }
            }
            .confirmationDialog(
                String(localized: "account.cover.removeConfirm.title"),
                isPresented: $flow.showRemoveConfirmation,
                titleVisibility: .visible
            ) {
                Button(String(localized: "account.cover.remove"), role: .destructive) {
                    guard let target = liveAccount else { return }
                    Task { await flow.remove(account: target, app: appViewModel) }
                }
                Button(String(localized: "common.cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "account.cover.removeConfirm.message"))
            }
    }
}

/// A decoded, upright photo to crop (CGImage is immutable — safe to hand
/// between the main actor and the encoder).
struct AccountCoverSource: @unchecked Sendable {
    let cgImage: CGImage

    var uiImage: UIImage { UIImage(cgImage: cgImage) }

    static func decode(_ data: Data) async -> AccountCoverSource? {
        await Task.detached(priority: .userInitiated) { () -> AccountCoverSource? in
            AccountCoverImageProcessor.decode(data).map(AccountCoverSource.init(cgImage:))
        }.value
    }
}

/// One showing of the crop screen (a navigation value: equal by `id`).
struct AccountCoverCropSession: Identifiable, Hashable {
    let id = UUID()
    let source: AccountCoverSource
    let initialCrop: CGRect?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Crop screen

/// Full-screen crop: the photo under a card-shaped window, pinch to zoom,
/// drag to pan — clamped so the window is always filled — with the card's
/// text live over the window. VoiceOver: adjustable zoom plus move actions.
struct AccountCoverCropView: View {
    /// `.pushed` on the account form's stack (the app);
    /// `.standalone` in its own stack (previews, the UI harness).
    enum Style { case pushed, standalone }

    let session: AccountCoverCropSession
    let account: Account
    let balanceText: String
    var style: Style = .standalone
    let onCancel: () -> Void
    let onDone: (CGRect) -> Void

    @State private var crop: AccountCoverCrop?
    @State private var zoomAtGestureStart: CGFloat?
    @State private var offsetAtGestureStart: CGSize?
    @State private var tone: AccountCoverTone = .unknown
    @State private var image: UIImage?

    private static let windowCornerRadius = CardStyle.Size.regular.cornerRadius

    var body: some View {
        switch style {
        case .standalone:
            NavigationStack { screen }
                .environment(\.colorScheme, .dark)
        case .pushed:
            screen
                // Cancel / Done only: no back button, and with it no edge
                // swipe that would drop the crop mid-pan.
                .navigationBarBackButtonHidden(true)
                // The system bar over the black screen (no custom bar
                // background — liquid-glass.md §2), its items light.
                .toolbarColorScheme(.dark, for: .navigationBar)
                .environment(\.colorScheme, .dark)
        }
    }

    private var screen: some View {
        GeometryReader { geometry in
                let viewport = AccountCoverCrop.viewportSize(fitting: geometry.size)
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height * 0.42)
                let window = CGRect(x: center.x - viewport.width / 2, y: center.y - viewport.height / 2,
                                    width: viewport.width, height: viewport.height)
                ZStack {
                    Color.black

                    if let crop, let image {
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: crop.displayedSize.width, height: crop.displayedSize.height)
                            .position(x: center.x + crop.offset.width, y: center.y + crop.offset.height)
                            .accessibilityHidden(true)
                    }

                    // Everything outside the window is dimmed.
                    AccountCoverWindowMask(window: window, cornerRadius: Self.windowCornerRadius)
                        .fill(Color.black.opacity(0.78), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                    // The card's text over the window, live.
                    ZStack {
                        AccountCoverScrimView(tone: tone)
                        AccountCoverCardText(account: account, balanceText: balanceText)
                            .padding(CardStyle.Size.regular.defaultPadding)
                    }
                    .frame(width: viewport.width, height: viewport.height)
                    .clipShape(RoundedRectangle(cornerRadius: Self.windowCornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.windowCornerRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.7), lineWidth: 1)
                    }
                    .position(center)
                    .allowsHitTesting(false)

                    // Near the bottom, clear of the photo however tall it is.
                    VStack {
                        Spacer(minLength: 0)
                        Text(String(localized: "account.cover.crop.hint"))
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                            .padding(.bottom, 56)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .gesture(cropGesture)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "account.cover.crop.a11y.label"))
                .accessibilityValue(zoomDescription)
                .accessibilityHint(String(localized: "account.cover.crop.a11y.hint"))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: zoom(by: 0.25)
                    case .decrement: zoom(by: -0.25)
                    @unknown default: break
                    }
                }
                // Named after where the PHOTO moves (as a drag would move it).
                .accessibilityAction(named: Text(String(localized: "account.cover.crop.a11y.left"))) { pan(dx: -1, dy: 0, viewport: viewport) }
                .accessibilityAction(named: Text(String(localized: "account.cover.crop.a11y.right"))) { pan(dx: 1, dy: 0, viewport: viewport) }
                .accessibilityAction(named: Text(String(localized: "account.cover.crop.a11y.up"))) { pan(dx: 0, dy: -1, viewport: viewport) }
                .accessibilityAction(named: Text(String(localized: "account.cover.crop.a11y.down"))) { pan(dx: 0, dy: 1, viewport: viewport) }
                .onAppear { layout(viewport: viewport) }
                .onChange(of: viewport) { _, newViewport in layout(viewport: newViewport) }
            }
            .ignoresSafeArea(edges: .bottom)
            .background(Color.black)
            .navigationTitle(String(localized: "account.cover.crop.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.done")) {
                        if let crop { onDone(crop.normalizedCropRect) }
                    }
                    .disabled(crop == nil)
                }
            }
            .task {
                image = session.source.uiImage
            }
    }

    // MARK: Gestures

    private var cropGesture: some Gesture {
        SimultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    guard var current = crop else { return }
                    let start = zoomAtGestureStart ?? current.zoom
                    zoomAtGestureStart = start
                    current.setZoom(start * value.magnification)
                    crop = current
                }
                .onEnded { _ in
                    zoomAtGestureStart = nil
                    measureTone()
                },
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard var current = crop else { return }
                    let start = offsetAtGestureStart ?? current.offset
                    offsetAtGestureStart = start
                    current.setOffset(CGSize(width: start.width + value.translation.width,
                                             height: start.height + value.translation.height))
                    crop = current
                }
                .onEnded { _ in
                    offsetAtGestureStart = nil
                    measureTone()
                }
        )
    }

    private func layout(viewport: CGSize) {
        let source = session.source
        let imageSize = CGSize(width: source.cgImage.width, height: source.cgImage.height)
        if let current = crop {
            guard current.viewportSize != viewport else { return }
            crop = AccountCoverCrop(imageSize: imageSize, viewportSize: viewport,
                                    normalizedCrop: current.normalizedCropRect)
        } else {
            crop = AccountCoverCrop(imageSize: imageSize, viewportSize: viewport,
                                    normalizedCrop: session.initialCrop)
        }
        measureTone()
    }

    /// The scrim of the preview follows the part of the photo in the
    /// window (re-measured when a gesture ends — cheap, 160 × 84 px).
    private func measureTone() {
        guard let crop else { return }
        tone = AccountCoverImageProcessor.tone(of: session.source.cgImage, crop: crop.normalizedCropRect)
    }

    private func zoom(by step: CGFloat) {
        guard var current = crop else { return }
        current.setZoom(current.zoom + step)
        crop = current
        measureTone()
    }

    /// Moves the photo a tenth of the window (VoiceOver actions).
    private func pan(dx: CGFloat, dy: CGFloat, viewport: CGSize) {
        guard var current = crop else { return }
        current.setOffset(CGSize(width: current.offset.width + dx * viewport.width / 10,
                                 height: current.offset.height + dy * viewport.height / 10))
        crop = current
        measureTone()
    }

    private var zoomDescription: String {
        let percent = Int(((crop?.zoom ?? 1) * 100).rounded())
        return String(format: String(localized: "account.cover.crop.a11y.zoom %lld"), percent)
    }
}

/// The screen with a rounded-rectangle hole (even-odd fill).
private struct AccountCoverWindowMask: Shape {
    let window: CGRect
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(in: window, cornerSize: CGSize(width: cornerRadius, height: cornerRadius), style: .continuous)
        return path
    }
}
