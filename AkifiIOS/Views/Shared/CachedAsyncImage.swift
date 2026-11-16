import SwiftUI
import CryptoKit

/// Two-tier image cache: NSCache (memory) + disk (Caches directory).
///
/// `NSCache` is thread-safe and the disk tier only touches files, so the
/// expensive parts (file read + decode, file write) run off the main actor.
/// The memory cost is the decoded bitmap size — it used to be measured by
/// re-encoding every downloaded image to PNG on the main thread (P8).
private final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let memory = NSCache<NSURL, UIImage>()
    private let diskDir: URL

    init() {
        memory.countLimit = 200
        memory.totalCostLimit = 50 * 1024 * 1024 // 50 MB

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskDir = caches.appendingPathComponent("ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    func memoryImage(for url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    /// Disk tier — call off the main actor.
    func diskImage(for url: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: diskPath(for: url)),
              let image = UIImage(data: data) else { return nil }
        memory.setObject(image, forKey: url as NSURL, cost: Self.cost(of: image))
        return image
    }

    /// Stores the downloaded bytes as-is (no re-encode) — call off the main actor.
    func store(_ image: UIImage, data: Data, for url: URL) {
        memory.setObject(image, forKey: url as NSURL, cost: Self.cost(of: image))
        try? data.write(to: diskPath(for: url), options: .atomic)
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        return cg.bytesPerRow * cg.height
    }

    private func diskPath(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = hash.compactMap { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent(name)
    }
}

/// A drop-in replacement for AsyncImage that caches downloaded images in memory.
struct CachedAsyncImage<Placeholder: View>: View {
    let url: URL
    let placeholder: () -> Placeholder

    @State private var uiImage: UIImage?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await loadImage()
        }
    }

    private func loadImage() async {
        let url = url
        // Memory hit: no hop off the main actor.
        if let cached = ImageCache.shared.memoryImage(for: url) {
            uiImage = cached
            return
        }

        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        if let cached = await Task.detached(priority: .utility, operation: {
            ImageCache.shared.diskImage(for: url)
        }).value {
            uiImage = cached
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let image = await Task.detached(priority: .utility) { () -> UIImage? in
                guard let image = UIImage(data: data) else { return nil }
                ImageCache.shared.store(image, data: data, for: url)
                return image
            }.value
            if let image { uiImage = image }
        } catch {
            // Silent — placeholder stays
        }
    }
}
