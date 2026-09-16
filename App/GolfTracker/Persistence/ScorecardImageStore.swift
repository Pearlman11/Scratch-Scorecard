import Foundation
import UIKit

/// Stores scorecard photographs on disk and hands back references to put in the database.
///
/// The golfer's original photograph is part of the round's record — the app promises it stays attached
/// forever — so it is written once, never overwritten by the processed version, and only deleted when its
/// round is.
actor ScorecardImageStore {

    static let shared = ScorecardImageStore()

    private let directory: URL
    private let fileManager = FileManager.default

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("ScorecardImages", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        excludeFromBackupIfNeeded()
    }

    struct StoredImages {
        let originalFilename: String
        let normalizedFilename: String?
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// Writes both versions of a scan and returns their filenames.
    ///
    /// The original is stored at high JPEG quality: it is the artefact the golfer keeps, and this is the
    /// only copy the app will ever hold of that moment.
    func store(_ processed: ProcessedScorecardImage, id: UUID = UUID()) throws -> StoredImages {
        guard let originalData = processed.original.jpegData(compressionQuality: 0.92) else {
            throw ImageStoreError.encodingFailed
        }
        let originalName = "\(id.uuidString)-original.jpg"
        try write(originalData, named: originalName)

        // The processed image only exists to explain a parse in the debug inspector, so it is stored small.
        var normalizedName: String?
        if let normalizedData = processed.normalized.jpegData(compressionQuality: 0.6) {
            let name = "\(id.uuidString)-normalized.jpg"
            if (try? write(normalizedData, named: name)) != nil {
                normalizedName = name
            }
        }

        return StoredImages(
            originalFilename: originalName,
            normalizedFilename: normalizedName,
            pixelWidth: Int(processed.original.size.width * processed.original.scale),
            pixelHeight: Int(processed.original.size.height * processed.original.scale)
        )
    }

    func url(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    func loadImage(named filename: String) -> UIImage? {
        UIImage(contentsOfFile: url(for: filename).path)
    }

    /// Removes an image pair. Called when a round is deleted.
    ///
    /// Missing files are not an error: a restore from backup, or a half-completed earlier delete, can leave
    /// a reference without its file, and refusing to delete the round because of that would strand it.
    func delete(originalFilename: String?, normalizedFilename: String?) {
        for name in [originalFilename, normalizedFilename].compactMap({ $0 }) {
            try? fileManager.removeItem(at: url(for: name))
        }
    }

    /// Deletes any file not referenced by a live record.
    ///
    /// A safety net for the case where the app is killed between writing an image and committing the round
    /// that points at it, which would otherwise leak a few megabytes per occurrence.
    func deleteOrphans(keeping referencedFilenames: Set<String>) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        // Grace period: a file written moments ago may belong to a scan still on the review screen.
        let cutoff = Date().addingTimeInterval(-3600)
        for file in contents {
            let name = file.lastPathComponent
            guard !referencedFilenames.contains(name) else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? fileManager.removeItem(at: file)
        }
    }

    func totalBytesOnDisk() -> Int {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return contents.reduce(0) { total, file in
            total + ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    // MARK: - Private

    private func write(_ data: Data, named filename: String) throws {
        try data.write(to: url(for: filename), options: [.atomic, .completeFileUntilFirstUserAuthentication])
    }

    /// Scorecard photos are reproducible from the golfer's own Photos library in most cases and can be
    /// large, so they are kept out of iCloud backup.
    private func excludeFromBackupIfNeeded() {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = directory
        try? mutableURL.setResourceValues(values)
    }
}

enum ImageStoreError: Error, LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "The scorecard photo could not be saved."
        }
    }
}
