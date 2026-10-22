import Foundation
import UIKit
import ImageIO

@MainActor
enum AccountPhotoStore {
    static let changed = Notification.Name("ledgerly.accountPhoto.changed")
    private static func url(_ uid: String) -> URL {
        let key = Data(uid.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AccountPhotos", isDirectory: true).appendingPathComponent(key + ".jpg")
    }
    static func preparedData(_ data: Data) throws -> Data {
        guard data.count <= 20_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary), let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return jpeg
    }
    static func data(_ uid: String) -> Data? { try? Data(contentsOf: url(uid)) }
    static func save(_ data: Data?, uid: String, preservingEncoded: Bool = false) throws {
        let destination = url(uid)
        if let data {
            guard data.count <= 20_000_000, (!preservingEncoded || data.count <= 256_000), let image = UIImage(data: data), image.size.width <= 512, image.size.height <= 512 else { throw CocoaError(.fileReadCorruptFile) }
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let edge: CGFloat = 512
            let scale = max(edge / image.size.width, edge / image.size.height)
            let bounds = CGRect(x: (edge - image.size.width * scale) / 2,
                                y: (edge - image.size.height * scale) / 2,
                                width: image.size.width * scale, height: image.size.height * scale)
            let rendered = UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge), format: format)
                .image { _ in image.draw(in: bounds) }
            guard let jpeg = preservingEncoded ? data : rendered.jpegData(compressionQuality: 0.75) else { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try jpeg.write(to: destination, options: [.atomic, .completeFileProtection])
            var file = destination; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try file.setResourceValues(values)
        } else if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        NotificationCenter.default.post(name: changed, object: uid)
    }
}
