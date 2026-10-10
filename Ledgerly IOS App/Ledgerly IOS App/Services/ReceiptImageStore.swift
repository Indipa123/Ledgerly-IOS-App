import Foundation
import UIKit

enum ReceiptImageStore {
    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Receipts", isDirectory: true)
    }

    private static func url(for id: UUID) -> URL {
        folder.appendingPathComponent(id.uuidString).appendingPathExtension("jpg")
    }

    static func save(_ data: Data, for id: UUID) throws {
        guard let image = UIImage(data: data) else { throw ReceiptImageError.invalidImage }
        let scale = min(1, 1800 / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, image.size.width * scale),
                          height: max(1, image.size.height * scale))
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = rendered.jpegData(compressionQuality: 0.75) else {
            throw ReceiptImageError.invalidImage
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var destination = url(for: id)
        try jpeg.write(to: destination, options: .atomic)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try destination.setResourceValues(values)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
                                              ofItemAtPath: destination.path)
    }

    static func image(for id: UUID) -> UIImage? {
        UIImage(contentsOfFile: url(for: id).path)
    }

    static func delete(for id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}

private enum ReceiptImageError: LocalizedError {
    case invalidImage
    var errorDescription: String? { "The receipt image could not be saved." }
}
