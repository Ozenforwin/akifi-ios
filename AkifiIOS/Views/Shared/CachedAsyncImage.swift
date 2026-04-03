import SwiftUI
import CryptoKit

/// Two-tier image cache: NSCache (memory) + disk (Caches directory).
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

    func image(for url: URL) -> UIImage? {
        // 1. Memory
        if let cached = memory.object(forKey: url as NSURL) { return cached }
        // 2. Disk
        let file = diskPath(for: url)
        guard let data = try? Data(contentsOf: file),
              let image = UIImage(data: data) else { return nil }
        memory.setObject(image, forKey: url as NSURL)
        return image
    }

    func store(_ image: UIImage, for url: URL) {
        let cost = image.pngData()?.count ?? 0
        memory.setObject(image, forKey: url as NSURL, cost: cost)
        // Write to disk in background
        let file = diskPath(for: url)
        if let data = image.jpegData(compressionQuality: 0.85) {
            try? data.write(to: file, options: .atomic)
        }
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
        // Check cache first
        if let cached = ImageCache.shared.image(for: url) {
            uiImage = cached
            return
        }

        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                ImageCache.shared.store(image, for: url)
                await MainActor.run { uiImage = image }
            }
        } catch {
            // Silent — placeholder stays
        }
    }
}
