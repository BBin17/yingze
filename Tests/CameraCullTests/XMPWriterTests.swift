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
        <rdf:Description xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="4" xmp:Label="Green"/>
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
        <rdf:Description xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:xmp="http://ns.adobe.com/xap/1.0/">
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
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:custom="urn:test" xmp:Rating="1" xmp:Label="Red" custom:Keep="yes"/></rdf:RDF></x:xmpmeta>
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
        <rdf:Description xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:xmp="http://ns.adobe.com/xap/1.0/">
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

    @Test("合并未声明 XMP 命名空间的有效边车文件")
    func addsXMPNamespaceWithoutChangingExistingMetadata() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).xmp")
        defer { try? FileManager.default.removeItem(at: url) }
        let existing = """
        <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <rdf:Description rdf:about=""><dc:format>image/jpeg</dc:format></rdf:Description>
        </rdf:RDF>
        <?xpacket end="w"?>
        """
        try Data(existing.utf8).write(to: url)
        let output = try XMPWriter().data(existingURL: url, rating: 3, label: .red)
        let document = try XMLDocument(data: output)
        let root = try #require(document.rootElement())
        let description = try #require(root.elements(forLocalName: "Description", uri: rdfURI).first)
        #expect(description.attribute(forLocalName: "Rating", uri: xmpURI)?.stringValue == "3")
        #expect(description.attribute(forLocalName: "Label", uri: xmpURI)?.stringValue == "Red")
        #expect(description.elements(forLocalName: "format", uri: "http://purl.org/dc/elements/1.1/").first?.stringValue == "image/jpeg")
        #expect(String(decoding: output, as: UTF8.self).contains("<?xpacket end=\"w\"?>"))
        #expect(try Data(contentsOf: url) == Data(existing.utf8))
    }

    @Test("按命名空间读取和更新 UTF-16 边车文件的自定义前缀")
    func updatesAlternativePrefixesWithoutChangingOtherSubjects() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).xmp")
        defer { try? FileManager.default.removeItem(at: url) }
        let existing = """
        <?xml version="1.0" encoding="UTF-16"?>
        <r:RDF xmlns:r="\(rdfURI)" xmlns:basic="\(xmpURI)" xmlns:xmp="urn:unrelated">
          <r:Description r:about="" xmp:Rating="custom">
            <basic:Rating>2</basic:Rating>
            <xmp:Description>海边 &amp; 森林</xmp:Description>
          </r:Description>
          <r:Description r:about="urn:other" basic:Rating="1" />
          <r:Description r:nodeID="another" basic:Rating="3" />
        </r:RDF>
        """
        try existing.write(to: url, atomically: true, encoding: .utf16)
        #expect(XMPReader().metadata(at: url)?.rating == 2)
        let output = try XMPWriter().data(existingURL: url, rating: 5, label: .purple)
        let document = try XMLDocument(data: output)
        let root = try #require(document.rootElement())
        let descriptions = root.elements(forLocalName: "Description", uri: rdfURI)
        try #require(descriptions.count == 3)
        let primary = descriptions[0]
        #expect(primary.elements(forLocalName: "Rating", uri: xmpURI).first?.stringValue == "5")
        #expect(primary.attribute(forLocalName: "Label", uri: xmpURI)?.stringValue == "Purple")
        #expect(primary.attribute(forLocalName: "Rating", uri: "urn:unrelated")?.stringValue == "custom")
        #expect(primary.elements(forLocalName: "Description", uri: "urn:unrelated").first?.stringValue == "海边 & 森林")
        #expect(descriptions[1].attribute(forLocalName: "Rating", uri: xmpURI)?.stringValue == "1")
        #expect(descriptions[2].attribute(forLocalName: "Rating", uri: xmpURI)?.stringValue == "3")
    }

    @Test("已有同名但不同命名空间的前缀时，新增属性仍属于 Adobe XMP")
    func addsNonConflictingNamespacePrefix() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).xmp")
        defer { try? FileManager.default.removeItem(at: url) }
        let existing = """
        <rdf:Description xmlns:rdf="\(rdfURI)" xmlns:xmp="urn:custom" xmp:Label="keep me"/>
        """
        try Data(existing.utf8).write(to: url)
        let output = try XMPWriter().data(existingURL: url, rating: 4, label: .yellow)
        let description = try #require(try XMLDocument(data: output).rootElement())
        #expect(description.attribute(forLocalName: "Label", uri: "urn:custom")?.stringValue == "keep me")
        #expect(description.attribute(forLocalName: "Label", uri: xmpURI)?.stringValue == "Yellow")
        #expect(description.attribute(forLocalName: "Rating", uri: xmpURI)?.stringValue == "4")
    }

    @Test("已有边车文件损坏时返回错误并保留原文件")
    func refusesMalformedExistingXMP() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).xmp")
        defer { try? FileManager.default.removeItem(at: url) }
        let broken = Data("<rdf:Description xmlns:rdf=\"\(rdfURI)\"><unfinished>".utf8)
        try broken.write(to: url)

        #expect(throws: XMPWriterError.self) {
            _ = try XMPWriter().data(existingURL: url, rating: 5, label: .none)
        }
        #expect(try Data(contentsOf: url) == broken)
    }

    private let rdfURI = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    private let xmpURI = "http://ns.adobe.com/xap/1.0/"
}
