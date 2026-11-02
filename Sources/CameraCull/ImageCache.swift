import AppKit
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct SendableCGImage: @unchecked Sendable {
    let value: CGImage
}

private final class ImageDecodeLimiter: @unchecked Sendable {
    private let semaphore: DispatchSemaphore
    init(limit: Int) { semaphore = DispatchSemaphore(value: limit) }
    func wait() { semaphore.wait() }
    func signal() { semaphore.signal() }
}

private let imageDecodeLimiter = ImageDecodeLimiter(limit: 4)
private let originalImageContext = CIContext(options: [.cacheIntermediates: false])

private enum ThumbnailDiskCache {
    static let maximumBytes: Int64 = 1_500_000_000

    static func fileURL(for source: URL, maxPixelSize: Int) -> URL? {
        guard let directory = directoryURL() else { return nil }
        let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let signature = [
            source.path,
            String(values?.fileSize ?? 0),
            String(values?.contentModificationDate?.timeIntervalSince1970 ?? 0),
            String(maxPixelSize)
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).jpg")
    }

    static func load(from url: URL) -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: false] as CFDictionary)
    }

    static func store(_ image: CGImage, at url: URL) {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { try? FileManager.default.removeItem(at: temporary); return }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: temporary) }
            else { try FileManager.default.moveItem(at: temporary, to: url) }
        } catch { try? FileManager.default.removeItem(at: temporary) }
    }

    static func pruneIfNeeded() {
        guard let directory = directoryURL(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey],
                options: [.skipsHiddenFiles]
              )
        else { return }
        let entries = files.compactMap { url -> (URL, Int64, Date) in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey])
            return (url, Int64(values?.fileSize ?? 0), values?.contentAccessDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.1 }
        guard total > maximumBytes else { return }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) {
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.1
            if total < maximumBytes * 2 / 3 { break }
        }
    }

    private static func directoryURL() -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = base.appendingPathComponent("Yingze/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@MainActor
final class ImageCache: ObservableObject {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, NSImage>()
    private var tasks: [String: Task<SendableCGImage?, Never>] = [:]

    private init() {
        cache.countLimit = 180
        cache.totalCostLimit = 768 * 1024 * 1024
        Task.detached(priority: .background) { ThumbnailDiskCache.pruneIfNeeded() }
    }

    func image(for url: URL, maxPixelSize: Int) async -> NSImage? {
        let key = "\(url.path)#\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if let task = tasks[key as String], let decoded = await task.value {
            return makeImage(decoded.value, key: key)
        }

        let task = Task.detached(priority: maxPixelSize > 1_000 ? .userInitiated : .utility) {
            Self.decode(url: url, maxPixelSize: maxPixelSize)
        }
        tasks[key as String] = task
        let decoded = await task.value
        tasks[key as String] = nil
        guard let decoded else { return nil }
        return makeImage(decoded.value, key: key)
    }

    private func makeImage(_ cgImage: CGImage, key: NSString) -> NSImage {
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key, cost: max(1, cgImage.width * cgImage.height * 4))
        return image
    }

    nonisolated private static func decode(url: URL, maxPixelSize: Int) -> SendableCGImage? {
        imageDecodeLimiter.wait()
        defer { imageDecodeLimiter.signal() }

        let usesDiskCache = maxPixelSize > 0 && maxPixelSize <= 2_048
        let diskURL = usesDiskCache ? ThumbnailDiskCache.fileURL(for: url, maxPixelSize: maxPixelSize) : nil
        if let diskURL, let cached = ThumbnailDiskCache.load(from: diskURL) {
            return SendableCGImage(value: cached)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        if maxPixelSize <= 0 {
            guard let cgImage = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: false] as CFDictionary
            ) else { return nil }
            return SendableCGImage(value: applyingOrientation(to: cgImage, source: source))
        }

        let isRenderedImage = ["jpg", "jpeg", "heic", "heif"].contains(url.pathExtension.lowercased())
        let options: [CFString: Any] = [
            isRenderedImage ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        if let diskURL { ThumbnailDiskCache.store(cgImage, at: diskURL) }
        return SendableCGImage(value: cgImage)
    }

    nonisolated private static func applyingOrientation(to image: CGImage, source: CGImageSource) -> CGImage {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let orientation = properties[kCGImagePropertyOrientation] as? NSNumber,
              orientation.int32Value != 1
        else { return image }

        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: orientation.int32Value)
        return originalImageContext.createCGImage(oriented, from: oriented.extent) ?? image
    }
}
