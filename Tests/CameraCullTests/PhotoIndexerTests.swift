import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CameraCull

@Suite("照片索引")
struct PhotoIndexerTests {
    @Test("大小写不敏感配对并标识孤立文件")
    func pairsFilesCaseInsensitivelyAndReportsOrphans() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("jpg".utf8).write(to: directory.appendingPathComponent("DSC0001.JPG"))
        try Data("heic".utf8).write(to: directory.appendingPathComponent("dsc0001.HeIc"))
        try Data("raw".utf8).write(to: directory.appendingPathComponent("dsc0001.arw"))
        try Data("raw".utf8).write(to: directory.appendingPathComponent("DSC0002.ARW"))
        try Data("ignored".utf8).write(to: directory.appendingPathComponent("notes.txt"))

        let groups = try await PhotoIndexer().scan(directory: directory) { _ in }

        #expect(groups.count == 2)
        #expect(groups[0].jpegURL != nil)
        #expect(groups[0].heicURL != nil)
        #expect(groups[0].rawURL != nil)
        #expect(!groups[0].isOrphan)
        #expect(groups[1].isOrphan)
    }

    @Test("一千组照片渐进索引")
    func indexesOneThousandPairsWithoutDecodingEveryImage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<1_000 {
            let name = String(format: "DSC%04d", index)
            try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: directory.appendingPathComponent("\(name).JPG"))
            try Data("raw".utf8).write(to: directory.appendingPathComponent("\(name).ARW"))
        }
        let counter = Counter()
        let start = ContinuousClock.now
        let groups = try await PhotoIndexer().scan(directory: directory, batchSize: 100) { batch in
            await counter.add(batch.count)
        }
        let elapsed = start.duration(to: .now)

        #expect(groups.count == 1_000)
        #expect(await counter.value == 1_000)
        #expect(elapsed < .seconds(15))
    }

    @Test("不同子目录的同名照片不会错误配对")
    func keepsDuplicateNamesInSeparateDirectories() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("100MSDCF")
        let second = directory.appendingPathComponent("101MSDCF")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        for folder in [first, second] {
            try Data("jpg".utf8).write(to: folder.appendingPathComponent("DSC0001.JPG"))
            try Data("raw".utf8).write(to: folder.appendingPathComponent("DSC0001.ARW"))
        }

        let groups = try await PhotoIndexer().scan(directory: directory) { _ in }
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { !$0.isOrphan })
        #expect(groups[0].id != groups[1].id)
    }

    @Test("识别主流相机 RAW 扩展名")
    func recognizesMainstreamCameraRawFormats() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let extensions = CameraRawFormat.supportedExtensions.sorted()
        for (index, ext) in extensions.enumerated() {
            try Data("raw".utf8).write(to: directory.appendingPathComponent("CAM\(index).\(ext.uppercased())"))
        }

        let groups = try await PhotoIndexer().scan(directory: directory) { _ in }
        #expect(groups.count == extensions.count)
        #expect(Set(groups.compactMap { $0.rawURL?.pathExtension.lowercased() }) == Set(extensions))
        #expect(groups.allSatisfy { $0.rawFormat != nil })
    }

    @Test("索引时读取已有 XMP 评分与颜色")
    func importsExistingXMPMetadata() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("jpg".utf8).write(to: directory.appendingPathComponent("DSC0003.JPG"))
        try Data("raw".utf8).write(to: directory.appendingPathComponent("DSC0003.ARW"))
        try """
        <rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="3" xmp:Label="Purple"/>
        """.write(to: directory.appendingPathComponent("dsc0003.xmp"), atomically: true, encoding: .utf8)

        let group = try #require(try await PhotoIndexer().scan(directory: directory) { _ in }.first)
        #expect(group.rating == 3)
        #expect(group.colorLabel == .purple)
    }

    @Test("同组出现重复类型时明确标记冲突")
    func reportsDuplicatePairingConflicts() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("jpg1".utf8).write(to: directory.appendingPathComponent("DUP.JPG"))
        try Data("jpg2".utf8).write(to: directory.appendingPathComponent("dup.JPEG"))
        try Data("raw1".utf8).write(to: directory.appendingPathComponent("DUP.ARW"))
        try Data("raw2".utf8).write(to: directory.appendingPathComponent("dup.SRF"))

        let group = try #require(try await PhotoIndexer().scan(directory: directory) { _ in }.first)
        #expect(group.hasPairingConflict)
        #expect(group.pairingConflicts?.count == 2)
        #expect(group.pairingConflictText.contains("JPG"))
        #expect(group.pairingConflictText.contains("RAW"))
    }

    @Test("读取快门光圈 ISO 焦段和相机镜头信息")
    func readsCaptureMetadataWithoutDecodingFullPreview() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("EXIF.JPG")
        try writeJPEGWithMetadata(to: url)

        let groups = try await PhotoIndexer().scan(directory: directory) { _ in }
        let group = try #require(groups.first)

        #expect(group.exposureTime == 1.0 / 1_000.0)
        #expect(group.fNumber == 2.8)
        #expect(group.iso == 400)
        #expect(group.focalLength == 200)
        #expect(group.shutterText == "1/1000 秒")
        #expect(group.apertureText == "f/2.8")
        #expect(group.isoText == "ISO 400")
        #expect(group.focalLengthText == "200 mm")
        #expect(group.cameraText == "Sony ILCE-7M4")
        #expect(group.lensModel == "FE 70-200mm F2.8 GM OSS II")
        #expect(group.displayDimensions == "16 × 10")
        #expect(group.captureDate != nil)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CameraCullTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeJPEGWithMetadata(to url: URL) throws {
        let context = try #require(CGContext(
            data: nil,
            width: 16,
            height: 10,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 10))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifExposureTime: 1.0 / 1_000.0,
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifISOSpeedRatings: [400],
                kCGImagePropertyExifFocalLength: 200.0,
                kCGImagePropertyExifLensModel: "FE 70-200mm F2.8 GM OSS II",
                kCGImagePropertyExifDateTimeOriginal: "2026:07:22 14:35:20"
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Sony",
                kCGImagePropertyTIFFModel: "ILCE-7M4"
            ]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }
}

private actor Counter {
    private(set) var value = 0
    func add(_ amount: Int) { value += amount }
}
