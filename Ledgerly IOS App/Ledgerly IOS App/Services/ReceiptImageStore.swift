import Foundation
import UIKit
import ImageIO

enum ReceiptImageStore {
    private static var owner: String?
    private static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Receipts", isDirectory: true)
    }
    private static func scopedFolder(_ uid: String?) -> URL {
        let key = uid.map { Data($0.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_") } ?? "guest"
        return root.appendingPathComponent("account-" + key, isDirectory: true)
    }
    private static var folder: URL { scopedFolder(owner) }
    static func setAccount(_ uid: String?) { owner = uid }

    /// Only copy legacy attachments referenced by this account's own ledger.
    static func migrateLegacy(_ ids: Set<UUID>, includeGuest: Bool = false) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sources = includeGuest ? [scopedFolder(nil), root] : [root]
        for id in ids {
            for ext in ["pages", "jpg"] {
                let name = "\(id).\(ext)"
                let destination = folder.appendingPathComponent(name)
                guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
                for sourceFolder in sources where sourceFolder != folder {
                    let source = sourceFolder.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: source.path) {
                        try FileManager.default.copyItem(at: source, to: destination)
                        break
                    }
                }
            }
        }
    }

    private static func url(for id: UUID) -> URL {
        folder.appendingPathComponent(id.uuidString).appendingPathExtension("jpg")
    }

    private static var pendingDeletionFolder: URL {
        folder.appendingPathComponent("PendingDeletion", isDirectory: true)
    }

    private static func pendingURL(for id: UUID) -> URL {
        pendingDeletionFolder.appendingPathComponent(id.uuidString).appendingPathExtension("jpg")
    }

    static func normalizedData(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1800
              ] as CFDictionary) else { throw ReceiptImageError.invalidImage }
        return try normalized(UIImage(cgImage: thumbnail))
    }

    static func normalized(_ image: UIImage) throws -> Data {
        var longest: CGFloat = 1800
        for _ in 0..<5 {
            let scale = min(1, longest / max(image.size.width, image.size.height))
            let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            for quality in [0.8, 0.6, 0.4, 0.25] {
                if let data = rendered.jpegData(compressionQuality: quality), data.count <= ReceiptPageArchive.maximumPageBytes {
                    return data
                }
            }
            longest *= 0.7
        }
        throw ReceiptImageError.invalidImage
    }

    private static func archiveURL(for id: UUID) -> URL {
        folder.appendingPathComponent(id.uuidString).appendingPathExtension("pages")
    }

    static func save(_ data: Data, for id: UUID) throws { try savePages([data], for: id) }

    static func savePages(_ data: [Data], for id: UUID) throws {
        let pages = try data.map { try normalizedData($0) }
        try saveArchive(JSONEncoder().encode(ReceiptPageArchive(pages: pages)), for: id)
    }

    static func saveArchive(_ data: Data, for id: UUID) throws {
        let archive = try ReceiptPageArchive.decode(data)
        guard archive.pages.allSatisfy({ page in
            guard let source = CGImageSourceCreateWithData(page as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
            return (1...1800).contains(width) && (1...1800).contains(height)
        }) else { throw ReceiptImageError.invalidImage }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var destination = archiveURL(for: id)
        try data.write(to: destination, options: .atomic)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try destination.setResourceValues(values)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
    }

    static func pages(for id: UUID) -> [Data] {
        if let data = try? Data(contentsOf: archiveURL(for: id)), let archive = try? ReceiptPageArchive.decode(data) {
            return archive.pages
        }
        return (try? Data(contentsOf: url(for: id))).map { [$0] } ?? []
    }

    static func image(for id: UUID) -> UIImage? { pages(for: id).first.flatMap(UIImage.init(data:)) }

    static func archiveForSync(for id: UUID) throws -> Data? {
        if let data = try? Data(contentsOf: archiveURL(for: id)) { return data }
        let legacy = pages(for: id)
        guard !legacy.isEmpty else { return nil }
        let normalizedPages = try legacy.map { data in
            guard let image = UIImage(data: data) else { throw ReceiptImageError.invalidImage }
            return try normalized(image)
        }
        return try JSONEncoder().encode(ReceiptPageArchive(pages: normalizedPages))
    }

    static func delete(for id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
        try? FileManager.default.removeItem(at: archiveURL(for: id))
        finishDeletion(for: id)
    }

    static func removeForAccountDeletion(_ ids: Set<UUID>, protected: Set<UUID> = [], includesClaimedGuest: Bool = false) throws {
        let folders = includesClaimedGuest ? [folder, scopedFolder(nil)] : [folder]
        for id in ids {
            for scope in Set(folders) {
                for base in [scope, scope.appendingPathComponent("PendingDeletion", isDirectory: true)] {
                    for ext in ["pages", "jpg"] {
                        let file = base.appendingPathComponent("\(id).\(ext)")
                        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                    }
                }
            }
            if !protected.contains(id) {
                for base in [root, root.appendingPathComponent("PendingDeletion", isDirectory: true)] {
                    for ext in ["pages", "jpg"] {
                        let file = base.appendingPathComponent("\(id).\(ext)")
                        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                    }
                }
            }
        }
    }

    static func stageDeletion(for id: UUID) throws {
        try FileManager.default.createDirectory(at: pendingDeletionFolder, withIntermediateDirectories: true)
        for source in [url(for: id), archiveURL(for: id)] where FileManager.default.fileExists(atPath: source.path) {
            let destination = pendingDeletionFolder.appendingPathComponent(source.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    static func restoreStaged(for id: UUID) throws {
        for destination in [url(for: id), archiveURL(for: id)] {
            let source = pendingDeletionFolder.appendingPathComponent(destination.lastPathComponent)
            if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.moveItem(at: source, to: destination) }
        }
    }

    static func finishDeletion(for id: UUID) {
        try? FileManager.default.removeItem(at: pendingURL(for: id))
        try? FileManager.default.removeItem(at: pendingDeletionFolder.appendingPathComponent("\(id).pages"))
    }

    static func clearInterruptedDeletions() {
        try? FileManager.default.removeItem(at: pendingDeletionFolder)
    }
}

private enum ReceiptImageError: LocalizedError {
    case invalidImage
    var errorDescription: String? { "The receipt image could not be saved." }
}
