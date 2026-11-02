import Foundation
import Testing
@testable import CameraCull

@Suite("XMP 边车")
struct XMPWriterTests {
    @Test("读取 Adobe 属性形式的评分与颜色")
    func readsAdobeAttributeMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CameraCullXMP-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("image.xmp")
        try """
        <rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="4" xmp:Label="Green"/>
        """.write(to: url, atomically: true, encoding: .utf8)

        let metadata = try #require(XMPReader().metadata(at: url))
        #expect(metadata.rating == 4)
        #expect(metadata.colorLabel == .green)
    }

    @Test("读取元素形式的评分与空颜色")
    func readsElementMetadataAndEmptyLabel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CameraCullXMP-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("image.xmp")
        try """
        <rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/">
          <xmp:Rating>5</xmp:Rating>
          <xmp:Label></xmp:Label>
        </rdf:Description>
        """.write(to: url, atomically: true, encoding: .utf8)

        let metadata = try #require(XMPReader().metadata(at: url))
        #expect(metadata.rating == 5)
        #expect(metadata.colorLabel == ColorLabel.none)
    }

    @Test("生成 Adobe 兼容评分与标签")
    func createsAdobeCompatibleXMP() throws {
        let data = try XMPWriter().data(existingURL: nil, rating: 4, label: .green)
        let xml = try #require(String(data: data, encoding: .utf8))
        #expect(xml.contains("xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\""))
        #expect(xml.contains("xmp:Rating=\"4\""))
        #expect(xml.contains("xmp:Label=\"Green\""))
    }

    @Test("合并评分并保留未知字段")
    func mergesRatingsAndPreservesUnknownFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CameraCullXMP-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("image.xmp")
        let existing = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:custom="urn:test" xmp:Rating="1" xmp:Label="Red" custom:Keep="yes"/></rdf:RDF></x:xmpmeta>
        """
        try existing.write(to: url, atomically: true, encoding: .utf8)

        let data = try XMPWriter().data(existingURL: url, rating: 5, label: .blue)
        let updated = try #require(String(data: data, encoding: .utf8))

        #expect(updated.contains("xmp:Rating=\"5\""))
        #expect(updated.contains("xmp:Label=\"Blue\""))
        #expect(updated.contains("custom:Keep=\"yes\""))
    }

    @Test("更新元素形式时不会产生重复属性")
    func updatesElementPropertiesWithoutDuplicatingThem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CameraCullXMP-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("image.xmp")
        try """
        <rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/">
          <xmp:Rating>1</xmp:Rating><xmp:Label>Red</xmp:Label>
        </rdf:Description>
        """.write(to: url, atomically: true, encoding: .utf8)

        let data = try XMPWriter().data(existingURL: url, rating: 4, label: .blue)
        let updated = try #require(String(data: data, encoding: .utf8))
        #expect(updated.contains("<xmp:Rating>4</xmp:Rating>"))
        #expect(updated.contains("<xmp:Label>Blue</xmp:Label>"))
        #expect(!updated.contains("xmp:Rating=\""))
        #expect(!updated.contains("xmp:Label=\""))
    }
}
