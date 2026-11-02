import Foundation

struct XMPMetadata: Equatable, Sendable {
    var rating: Int?
    var colorLabel: ColorLabel?
}

struct XMPReader: Sendable {
    func metadata(at url: URL?) -> XMPMetadata? {
        guard let url,
              let xml = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }

        let rating = value(named: "xmp:Rating", in: xml)
            .flatMap(Int.init)
            .map { min(5, max(0, $0)) }
        let label = value(named: "xmp:Label", in: xml)
            .flatMap(colorLabel)
        guard rating != nil || label != nil else { return nil }
        return XMPMetadata(rating: rating, colorLabel: label)
    }

    private func value(named name: String, in xml: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let patterns = [
            "\\b\(escapedName)\\s*=\\s*([\"'])(.*?)\\1",
            "<\(escapedName)\\b[^>]*>(.*?)</\(escapedName)>"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ),
            let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
            match.numberOfRanges > 1
            else { continue }
            let valueRange = match.numberOfRanges > 2 ? match.range(at: 2) : match.range(at: 1)
            guard let range = Range(valueRange, in: xml) else { continue }
            return String(xml[range])
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
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
        let ratingValue = rating == 0 ? "0" : String(min(5, max(-1, rating)))
        let escapedLabel = escape(label.rawValue)
        guard let existingURL else { return Data(template(rating: ratingValue, label: escapedLabel).utf8) }
        guard let original = try? String(contentsOf: existingURL, encoding: .utf8),
              original.range(of: "<rdf:Description", options: .caseInsensitive) != nil
        else { throw XMPWriterError.malformedExistingXMP(existingURL) }

        var output = replacingAttribute(in: original, name: "xmp:Rating", value: ratingValue)
        output = replacingAttribute(in: output, name: "xmp:Label", value: escapedLabel)
        return Data(output.utf8)
    }

    func writeAtomically(_ data: Data, to destination: URL) throws {
        let manager = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
    }

    private func replacingAttribute(in xml: String, name: String, value: String) -> String {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = "\\b\(escapedName)\\s*=\\s*([\"']).*?\\1"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
           regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)) != nil {
            return regex.stringByReplacingMatches(
                in: xml,
                range: NSRange(xml.startIndex..., in: xml),
                withTemplate: "\(name)=\"\(value)\""
            )
        }
        let elementPattern = "(<\(escapedName)\\b[^>]*>).*?(</\(escapedName)>)"
        if let regex = try? NSRegularExpression(
            pattern: elementPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ),
        regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)) != nil {
            return regex.stringByReplacingMatches(
                in: xml,
                range: NSRange(xml.startIndex..., in: xml),
                withTemplate: "$1\(value)$2"
            )
        }
        guard let range = xml.range(of: "<rdf:Description", options: .caseInsensitive) else { return xml }
        return xml.replacingCharacters(in: range, with: "<rdf:Description \(name)=\"\(value)\"")
    }

    private func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func template(rating: String, label: String) -> String {
        """
        <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="\(rating)" xmp:Label="\(label)"/>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }
}
