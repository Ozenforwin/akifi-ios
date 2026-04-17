import Foundation
import UIKit
import SwiftUI
import PhotosUI

/// Handles uploading journal photos to Supabase Storage bucket `journal-photos`.
///
/// Path format: `{userId}/{noteId}/{uuid}.jpg`
/// Each photo resized to max 1600px on the longer edge, JPEG quality 0.75.
/// Public bucket — public URL persisted on the note's `photo_urls` column.
@MainActor
final class JournalPhotoUploader {

    static let bucket = "journal-photos"
    private static let maxEdge: CGFloat = 1600
    private static let compressionQuality: CGFloat = 0.75

    enum UploadError: LocalizedError {
        case loadFailed
        case decodeFailed
        case compressionFailed

        var errorDescription: String? {
            switch self {
            case .loadFailed: String(localized: "journal.upload.error.load")
            case .decodeFailed: String(localized: "journal.upload.error.decode")
            case .compressionFailed: String(localized: "journal.upload.error.compression")
            }
        }
    }

    /// Upload a single PhotosPickerItem.
    /// Returns the public URL string for the uploaded photo.
    /// `onProgress` receives values 0.0...1.0 (simplified — Supabase-Swift doesn't
    /// surface per-chunk progress, so we emit 0 at start and 1 on completion).
    static func upload(
        item: PhotosPickerItem,
        userId: String,
        noteId: String,
        onProgress: @escaping (Double) -> Void
    ) async throws -> String {
        onProgress(0)

        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw UploadError.loadFailed
        }
        guard let image = UIImage(data: data) else {
            throw UploadError.decodeFailed
        }
        let resized = resize(image, maxEdge: maxEdge)
        guard let jpegData = resized.jpegData(compressionQuality: compressionQuality) else {
            throw UploadError.compressionFailed
        }

        onProgress(0.2)

        let photoId = UUID().uuidString.lowercased()
        let path = "\(userId)/\(noteId)/\(photoId).jpg"

        _ = try await SupabaseManager.shared.client.storage
            .from(bucket)
            .upload(
                path,
                data: jpegData,
                options: .init(contentType: "image/jpeg", upsert: false)
            )

        onProgress(0.9)

        let publicURL = try SupabaseManager.shared.client.storage
            .from(bucket)
            .getPublicURL(path: path)

        onProgress(1.0)
        return publicURL.absoluteString
    }

    /// Remove a photo from storage given its public URL.
    /// Best-effort — silently ignores failures (e.g. path mismatch).
    static func delete(publicURL: String) async {
        guard let path = storagePath(from: publicURL) else { return }
        _ = try? await SupabaseManager.shared.client.storage
            .from(bucket)
            .remove(paths: [path])
    }

    /// Extract the storage path (userId/noteId/uuid.jpg) from a public URL.
    /// Public URLs look like: `https://<project>.supabase.co/storage/v1/object/public/journal-photos/<path>`
    private static func storagePath(from publicURL: String) -> String? {
        guard let url = URL(string: publicURL) else { return nil }
        let components = url.pathComponents
        guard let idx = components.firstIndex(of: bucket), idx + 1 < components.count else {
            return nil
        }
        return components[(idx + 1)...].joined(separator: "/")
    }

    private static func resize(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxEdge else { return image }
        let ratio = maxEdge / longest
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
