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

/// The «Обложка» section of the account form. The owner picks a photo
/// (system picker, no library permission), crops it, changes the area or
/// removes it — each applies at once, like the sharing sheet next to it.
/// Members of a shared account see the cover and who may change it.
struct AccountCoverSection: View {
    let account: Account

    @Environment(AppViewModel.self) private var appViewModel
    @State private var pickerItem: PhotosPickerItem?
    @State private var cropSession: AccountCoverCropSession?
    @State private var isPreparing = false
    @State private var isApplying = false
    @State private var errorMessage: String?
    @State private var showRemoveConfirmation = false

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
        isPreparing || isApplying || covers.busyAccountIds.contains(account.id)
    }

    private var balanceText: String {
        let balance = dataStore.balance(for: liveAccount)
        let fmt = appViewModel.currencyManager
        return balance < 0 ? "-\(fmt.formatAmount(balance.displayAmount))" : fmt.formatAmount(balance.displayAmount)
    }

    var body: some View {
        Section {
            preview
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))

            if canEdit {
                // Out-of-process picker: no photo-library permission. Images
                // only; HEIC is fine (ImageIO decodes it), so no transcoding.
                let pickTitle = String(localized: hasCover ? "account.cover.replace" : "account.cover.choose")
                PhotosPicker(selection: $pickerItem, matching: .images, preferredItemEncoding: .current) {
                    Label(pickTitle, systemImage: "photo.on.rectangle")
                }
                .disabled(isBusy)

                if hasCover {
                    Button {
                        Task { await editArea() }
                    } label: {
                        Label(String(localized: "account.cover.editArea"), systemImage: "crop")
                    }
                    .disabled(isBusy)

                    Button(role: .destructive) {
                        showRemoveConfirmation = true
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

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(Color.expense)
            }
        } header: {
            Text(String(localized: "account.cover.section"))
        } footer: {
            Text(String(localized: canEdit ? "account.cover.footer.owner" : "account.cover.footer.member"))
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            Task { await preparePicked(item) }
        }
        .fullScreenCover(item: $cropSession) { session in
            AccountCoverCropView(
                session: session,
                account: liveAccount,
                balanceText: balanceText,
                onCancel: { cropSession = nil },
                onDone: { crop in
                    cropSession = nil
                    Task { await apply(session.source, crop: crop) }
                }
            )
        }
        .confirmationDialog(
            String(localized: "account.cover.removeConfirm.title"),
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "account.cover.remove"), role: .destructive) {
                Task { await remove() }
            }
            Button(String(localized: "common.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "account.cover.removeConfirm.message"))
        }
        .task(id: liveAccount.coverPath) {
            await covers.load(liveAccount.coverPath)
        }
    }

    // MARK: Preview

    private var preview: some View {
        let shape = RoundedRectangle(cornerRadius: CardStyle.Size.compact.cornerRadius, style: .continuous)
        let cover = covers.image(for: liveAccount.coverPath)
        return ZStack {
            if let cover {
                AccountCoverBackdrop(cover: cover)
                AccountCoverCardText(account: liveAccount, balanceText: balanceText, compact: true)
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

    // MARK: Actions

    private func preparePicked(_ item: PhotosPickerItem) async {
        errorMessage = nil
        isPreparing = true
        defer { isPreparing = false }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let source = await AccountCoverSource.decode(data) else {
            errorMessage = AccountCoverErrorMessage.text(for: AccountCoverError.unreadableImage)
            return
        }
        cropSession = AccountCoverCropSession(source: source, initialCrop: nil)
    }

    /// «Изменить область»: the original photo when this device chose it
    /// (zoom out again), else the cover itself (zoom in further).
    private func editArea() async {
        errorMessage = nil
        isPreparing = true
        defer { isPreparing = false }
        let account = liveAccount
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

    private func apply(_ source: AccountCoverSource, crop: CGRect) async {
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
            let account = liveAccount
            let path = try await covers.setCover(jpeg, for: account)
            dataStore.setCoverPath(path, forAccountId: account.id)
            if let original = encoded.original {
                await covers.saveOriginal(original, crop: crop, coverPath: path)
            }
            HapticManager.success()
        } catch {
            errorMessage = AccountCoverErrorMessage.text(for: error)
        }
    }

    private func remove() async {
        errorMessage = nil
        do {
            let account = liveAccount
            try await covers.removeCover(of: account)
            dataStore.setCoverPath(nil, forAccountId: account.id)
        } catch {
            errorMessage = AccountCoverErrorMessage.text(for: error)
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

/// One presentation of the crop screen.
struct AccountCoverCropSession: Identifiable {
    let id = UUID()
    let source: AccountCoverSource
    let initialCrop: CGRect?
}

// MARK: - Crop screen

/// Full-screen crop: the photo under a card-shaped window, pinch to zoom,
/// drag to pan — clamped so the window is always filled — with the card's
/// text live over the window. VoiceOver: adjustable zoom plus move actions.
struct AccountCoverCropView: View {
    let session: AccountCoverCropSession
    let account: Account
    let balanceText: String
    let onCancel: () -> Void
    let onDone: (CGRect) -> Void

    @State private var crop: AccountCoverCrop?
    @State private var zoomAtGestureStart: CGFloat?
    @State private var offsetAtGestureStart: CGSize?
    @State private var tone: AccountCoverTone = .unknown
    @State private var image: UIImage?

    private static let windowCornerRadius = CardStyle.Size.regular.cornerRadius

    var body: some View {
        NavigationStack {
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
        }
        .environment(\.colorScheme, .dark)
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
