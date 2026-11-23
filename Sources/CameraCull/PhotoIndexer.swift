import Foundation
import ImageIO

enum PhotoIndexerError: LocalizedError {
    case unreadableDirectory(URL)

    var errorDescription: String? {
        switch self {
        case .unreadableDirectory(let url):
            "无法读取文件夹：\(url.path)\n请确认来源磁盘或 NAS 已连接，且文件夹可访问。"
        }
    }
}

struct PhotoIndexer: Sendable {
    private struct Bucket {
        var name: String
        var jpegs: [URL] = []
        var heics: [URL] = []
        var raws: [URL] = []
        var xmps: [URL] = []

        mutating func sort() {
            jpegs.sort(by: Self.urlOrder)
            heics.sort(by: Self.urlOrder)
            raws.sort(by: Self.urlOrder)
            xmps.sort(by: Self.urlOrder)
        }

        var conflicts: [String] {
            [
                conflict("JPG", urls: jpegs),
                conflict("HEIC", urls: heics),
                conflict("RAW", urls: raws),
                conflict("XMP", urls: xmps)
            ].compactMap { $0 }
        }

        private func conflict(_ kind: String, urls: [URL]) -> String? {
            guard urls.count > 1 else { return nil }
            return "\(kind)：\(urls.map(\.lastPathComponent).joined(separator: "、"))"
        }

        private static func urlOrder(_ lhs: URL, _ rhs: URL) -> Bool {
            lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }
    }

    private static let jpegExtensions: Set<String> = ["jpg", "jpeg"]
    private static let heicExtensions: Set<String> = ["heic", "heif"]
    private static let rawExtensions = CameraRawFormat.supportedExtensions
    private static let xmpExtensions: Set<String> = ["xmp"]

    func scan(
        directory: URL,
        batchSize: Int = 100,
        includeCaptureMetadata: Bool = true,
        onBatch: @escaping @Sendable ([PhotoGroup]) async -> Void
    ) async throws -> [PhotoGroup] {
        try Task.checkCancellation()
        try validateDirectory(directory)

        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        var failedDirectory: URL?
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, _ in
                failedDirectory = url
                return false
            }
        ) else { throw PhotoIndexerError.unreadableDirectory(directory) }

        let buckets = try collectBuckets(enumerator: enumerator, root: directory, keys: keys)
        if let failedDirectory { throw PhotoIndexerError.unreadableDirectory(failedDirectory) }

        let sorted = buckets.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var result: [PhotoGroup] = []
        result.reserveCapacity(sorted.count)
        var batch: [PhotoGroup] = []

        for key in sorted {
            try Task.checkCancellation()
            guard var bucket = buckets[key] else { continue }
            bucket.sort()
            guard !bucket.jpegs.isEmpty || !bucket.heics.isEmpty || !bucket.raws.isEmpty else { continue }
            var group = PhotoGroup(
                id: key,
                baseName: bucket.name,
                jpegURL: bucket.jpegs.first,
                heicURL: bucket.heics.first,
                rawURL: bucket.raws.first,
                xmpURL: bucket.xmps.first,
                captureDate: nil,
                pixelWidth: nil,
                pixelHeight: nil,
                pairingConflicts: bucket.conflicts
            )
            if includeCaptureMetadata {
                group = PhotoMetadataReader.enrich(group)
            }
            if let metadata = XMPReader().metadata(at: bucket.xmps.first) {
                if let rating = metadata.rating { group.rating = rating }
                if let colorLabel = metadata.colorLabel { group.colorLabel = colorLabel }
            }
            result.append(group)
            batch.append(group)
            if batch.count >= batchSize {
                await onBatch(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { await onBatch(batch) }
        try Task.checkCancellation()
        try validateDirectory(directory)
        return result
    }

    private func validateDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              manager.isReadableFile(atPath: url.path)
        else { throw PhotoIndexerError.unreadableDirectory(url) }
    }

    private func collectBuckets(
        enumerator: FileManager.DirectoryEnumerator,
        root: URL,
        keys: Set<URLResourceKey>
    ) throws -> [String: Bucket] {
        var buckets: [String: Bucket] = [:]
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            guard Self.jpegExtensions.contains(ext) || Self.heicExtensions.contains(ext) || Self.rawExtensions.contains(ext) || Self.xmpExtensions.contains(ext) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            let relativeParent = url.deletingLastPathComponent().path.replacingOccurrences(of: root.path, with: "", options: [.anchored])
            let key = "\(relativeParent)/\(name)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            var bucket = buckets[key] ?? Bucket(name: name)
            if Self.jpegExtensions.contains(ext) { bucket.jpegs.append(url) }
            if Self.heicExtensions.contains(ext) { bucket.heics.append(url) }
            if Self.rawExtensions.contains(ext) { bucket.raws.append(url) }
            if Self.xmpExtensions.contains(ext) { bucket.xmps.append(url) }
            buckets[key] = bucket
        }
        return buckets
    }

}

enum PhotoMetadataReader {
    struct Values: Sendable {
        var captureDate: Date?
        var pixelWidth: Int?
        var pixelHeight: Int?
        var exposureTime: Double?
        var fNumber: Double?
        var iso: Int?
        var focalLength: Double?
        var lensModel: String?
        var cameraMake: String?
        var cameraModel: String?

        var needsRawFallback: Bool {
            exposureTime == nil || fNumber == nil || iso == nil || focalLength == nil
        }

        func applying(to group: PhotoGroup) -> PhotoGroup {
            var enriched = group
            enriched.captureDate = captureDate
            enriched.pixelWidth = pixelWidth
            enriched.pixelHeight = pixelHeight
            enriched.exposureTime = exposureTime
            enriched.fNumber = fNumber
            enriched.iso = iso
            enriched.focalLength = focalLength
            enriched.lensModel = lensModel
            enriched.cameraMake = cameraMake
            enriched.cameraModel = cameraModel
            return enriched
        }

        func fillingMissing(from fallback: Values?) -> Values {
            guard let fallback else { return self }
            return Values(
                captureDate: captureDate ?? fallback.captureDate,
                pixelWidth: pixelWidth ?? fallback.pixelWidth,
                pixelHeight: pixelHeight ?? fallback.pixelHeight,
                exposureTime: exposureTime ?? fallback.exposureTime,
                fNumber: fNumber ?? fallback.fNumber,
                iso: iso ?? fallback.iso,
                focalLength: focalLength ?? fallback.focalLength,
                lensModel: lensModel ?? fallback.lensModel,
                cameraMake: cameraMake ?? fallback.cameraMake,
                cameraModel: cameraModel ?? fallback.cameraModel
            )
        }
    }

    static func enrich(_ group: PhotoGroup) -> PhotoGroup {
        metadata(for: group)?.applying(to: group) ?? group
    }

    static func metadata(for group: PhotoGroup) -> Values? {
        guard !group.hasCaptureMetadata else { return nil }
        let renderedURL = group.renderedPreviewURL
        let primaryURL = renderedURL ?? group.rawURL
        var values = read(from: primaryURL)
        if values?.needsRawFallback == true, let rawURL = group.rawURL, rawURL != primaryURL {
            values = values?.fillingMissing(from: read(from: rawURL)) ?? read(from: rawURL)
        }
        return values
    }

    private static func read(from url: URL?) -> Values? {
        guard let url,
              let source = CGImageSourceCreateWithURL(
                url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        return Values(
            captureDate: captureDate(exif[kCGImagePropertyExifDateTimeOriginal] as? String),
            pixelWidth: number(properties[kCGImagePropertyPixelWidth])?.intValue,
            pixelHeight: number(properties[kCGImagePropertyPixelHeight])?.intValue,
            exposureTime: number(exif[kCGImagePropertyExifExposureTime])?.doubleValue,
            fNumber: number(exif[kCGImagePropertyExifFNumber])?.doubleValue,
            iso: isoValue(exif[kCGImagePropertyExifISOSpeedRatings]),
            focalLength: number(exif[kCGImagePropertyExifFocalLength])?.doubleValue,
            lensModel: cleaned(exif[kCGImagePropertyExifLensModel] as? String),
            cameraMake: cleaned(tiff[kCGImagePropertyTIFFMake] as? String),
            cameraModel: cleaned(tiff[kCGImagePropertyTIFFModel] as? String)
        )
    }

    private static func number(_ value: Any?) -> NSNumber? {
        if let number = value as? NSNumber { return number }
        if let string = value as? String, let double = Double(string) { return NSNumber(value: double) }
        return nil
    }

    private static func isoValue(_ value: Any?) -> Int? {
        if let number = number(value) { return number.intValue }
        if let values = value as? [NSNumber] { return values.first?.intValue }
        if let values = value as? [Any] { return number(values.first)?.intValue }
        return nil
    }

    private static func captureDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty else { return nil }
        return cleaned
    }
}
