import Foundation

struct XMPMetadata: Equatable, Sendable {
    var rating: Int?
    var colorLabel: ColorLabel?
}
struct XMPReader: Sendable {
    func metadata(at url: URL?) -> XMPMetadata? {
        guard let url, let packet = try? XMPPacket(at: url) else { return nil }
        let rating = packet.properties(named: "Rating").first?.stringValue
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap(Int.init)
            .map { min(5, max(0, $0)) }
        let label = packet.properties(named: "Label").first?.stringValue
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap(colorLabel)
        guard rating != nil || label != nil else { return nil }
        return XMPMetadata(rating: rating, colorLabel: label)
    }

    private func colorLabel(_ value: String) -> ColorLabel? {
        if value.isEmpty { return ColorLabel.none }
        return ColorLabel.allCases.first {
            $0 != .none && $0.rawValue.caseInsensitiveCompare(value) == .orderedSame
        }
    }
}

enum XMPWriterError: LocalizedError {
    case malformedExistingXMP(URL)

    var errorDescription: String? {
        switch self {
        case .malformedExistingXMP(let url): "现有 XMP 无法解析：\(url.lastPathComponent)"
        }
    }
}

struct XMPWriter: Sendable {
    func data(existingURL: URL?, rating: Int, label: ColorLabel) throws -> Data {
        let ratingValue = String(min(5, max(-1, rating)))
        guard let existingURL else {
            return Data(template(rating: ratingValue, label: label.rawValue).utf8)
        }
        let packet = try XMPPacket(at: existingURL)
        packet.setProperty(named: "Rating", to: ratingValue)
        packet.setProperty(named: "Label", to: label.rawValue)
        packet.document.characterEncoding = "UTF-8"
        return packet.document.xmlData(options: [.nodePreserveWhitespace])
    }

    private func template(rating: String, label: String) -> String {
        """
        <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="\(XMPPacket.rdfURI)">
            <rdf:Description rdf:about="" xmlns:xmp="\(XMPPacket.xmpURI)" xmp:Rating="\(rating)" xmp:Label="\(label)"/>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }
}

private struct XMPPacket {
    static let rdfURI = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let xmpURI = "http://ns.adobe.com/xap/1.0/"

    let document: XMLDocument
    private let descriptions: [XMLElement]

    init(at url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever, .nodePreserveWhitespace]),
              document.dtd == nil,
              let root = document.rootElement()
        else { throw XMPWriterError.malformedExistingXMP(url) }

        let candidates: [XMLElement]
        if root.localName == "Description", root.uri == Self.rdfURI {
            candidates = [root]
        } else {
            let rdf = root.localName == "RDF" && root.uri == Self.rdfURI
                ? root
                : root.elements(forLocalName: "RDF", uri: Self.rdfURI).first
            candidates = rdf?.elements(forLocalName: "Description", uri: Self.rdfURI) ?? []
        }
        guard let primary = candidates.first(where: { Self.subject(of: $0) == "" }) ?? candidates.first else {
            throw XMPWriterError.malformedExistingXMP(url)
        }
        let subject = Self.subject(of: primary)
        self.document = document
        descriptions = subject.map { subject in
            candidates.filter { Self.subject(of: $0) == subject }
        } ?? [primary]
    }

    private static func subject(of description: XMLElement) -> String? {
        description.attribute(forLocalName: "about", uri: rdfURI)?.stringValue
    }

    func properties(named name: String) -> [XMLNode] {
        descriptions.flatMap { description -> [XMLNode] in
            let attribute = description.attribute(forLocalName: name, uri: Self.xmpURI)
            return [attribute].compactMap { $0 } + description.elements(forLocalName: name, uri: Self.xmpURI)
        }
    }

    func setProperty(named name: String, to value: String) {
        let existing = properties(named: name)
        if let first = existing.first {
            first.stringValue = value
            for duplicate in existing.dropFirst() { duplicate.detach() }
            return
        }

        let description = descriptions[0]
        var prefix = description.resolvePrefix(forNamespaceURI: Self.xmpURI) ?? ""
        if prefix.isEmpty {
            prefix = "xmp"
            var index = 1
            while description.resolveNamespace(forName: "\(prefix):\(name)") != nil {
                prefix = "xmp\(index)"
                index += 1
            }
            let namespace = XMLNode.namespace(withName: prefix, stringValue: Self.xmpURI) as! XMLNode
            description.addNamespace(namespace)
        }
        let attribute = XMLNode.attribute(withName: "\(prefix):\(name)", uri: Self.xmpURI, stringValue: value) as! XMLNode
        description.addAttribute(attribute)
    }
}
