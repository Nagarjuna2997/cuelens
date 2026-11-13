import Foundation
import PDFKit
import Compression

enum KnowledgeImportError: LocalizedError {
    case tooLarge, unsupported, noText, unreadableWordFile

    var errorDescription: String? {
        switch self {
        case .tooLarge: "Choose a file under 12 MB. PDF extraction is limited to 100 pages."
        case .unsupported: "Choose a PDF, DOCX, TXT, or Markdown file."
        case .noText: "This file has no readable text. Try a searchable PDF or paste the text into your assistant."
        case .unreadableWordFile: "CueLens couldn’t extract this DOCX. Try resaving it as DOCX or TXT."
        }
    }
}

enum KnowledgeImport {
    static let textLimit = 100_000
    static let documentLimit = 20

    static func read(_ url: URL, kind: MaterialKind) throws -> KnowledgeFile {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 12_000_000 else {
            throw KnowledgeImportError.tooLarge
        }

        let text: String?
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let pdf = PDFDocument(url: url), !pdf.isLocked else { throw KnowledgeImportError.noText }
            guard pdf.pageCount <= 100 else { throw KnowledgeImportError.tooLarge }
            var pages = ""
            for index in 0..<pdf.pageCount {
                try Task.checkCancellation()
                if let page = pdf.page(at: index)?.string {
                    pages += String(page.prefix(textLimit - pages.count)) + "\n"
                }
                if pages.count >= textLimit { break }
            }
            text = pages
        case "txt", "md", "markdown":
            let data = try Data(contentsOf: url)
            text = String(data: data, encoding: .utf8)
                ?? (data.starts(with: [255, 254]) || data.starts(with: [254, 255]) ? String(data: data, encoding: .utf16) : nil)
        case "docx":
            text = try WordText.extract(from: Data(contentsOf: url))
        default:
            throw KnowledgeImportError.unsupported
        }

        let clean = text?.replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !clean.isEmpty else { throw KnowledgeImportError.noText }
        return KnowledgeFile(name: url.lastPathComponent, text: String(clean.prefix(textLimit)), kind: kind)
    }
}

private final class WordText: NSObject, XMLParserDelegate {
    private var text = ""
    private var inText = false
    private var size = 0
    private var limitReached = false
    private var prohibitedEntity = false

    static func extract(from data: Data) throws -> String {
        let xml = try WordArchive(data: data).document()
        let parser = XMLParser(data: xml)
        let reader = WordText()
        parser.shouldProcessNamespaces = true
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = reader
        let parsed = parser.parse()
        guard !reader.prohibitedEntity, parsed || reader.limitReached else { throw KnowledgeImportError.unreadableWordFile }
        return reader.text
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "t" { inText = true }
        if elementName == "tab" { append("\t", parser: parser) }
        if elementName == "br" { append("\n", parser: parser) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" { inText = false }
        if elementName == "p" { append("\n", parser: parser) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { append(string, parser: parser) }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        prohibitedEntity = true
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        prohibitedEntity = true
        parser.abortParsing()
    }

    private func append(_ string: String, parser: XMLParser) {
        let addition = string.prefix(KnowledgeImport.textLimit - size)
        text += addition
        size += addition.count
        if size >= KnowledgeImport.textLimit {
            limitReached = true
            parser.abortParsing()
        }
    }
}

// Read only word/document.xml. Enforce sizes before allocating or expanding the entry.
private struct WordArchive {
    let data: Data
    private let maxExpandedSize = 5_000_000

    func document() throws -> Data {
        let failure = KnowledgeImportError.unreadableWordFile
        guard data.count >= 22 else { throw failure }
        let lower = max(0, data.count - 65_557)
        guard let end = (lower...data.count - 22).reversed().first(where: {
            number($0, count: 4) == 0x06054b50 && $0 + 22 + number($0 + 20, count: 2) == data.count
        }) else { throw failure }
        let entryCount = number(end + 10, count: 2)
        var offset = number(end + 16, count: 4)
        guard entryCount <= 4_096 else { throw failure }

        for _ in 0..<entryCount {
            guard offset + 46 <= end, number(offset, count: 4) == 0x02014b50 else { throw failure }
            let nameSize = number(offset + 28, count: 2)
            let nameOffset = offset + 46
            let next = nameOffset + nameSize + number(offset + 30, count: 2) + number(offset + 32, count: 2)
            guard next <= end else { throw failure }
            if data[nameOffset..<(nameOffset + nameSize)].elementsEqual("word/document.xml".utf8) {
                let method = number(offset + 10, count: 2)
                let flags = number(offset + 8, count: 2)
                let compressed = number(offset + 20, count: 4)
                let expanded = number(offset + 24, count: 4)
                let local = number(offset + 42, count: 4)
                guard flags & 1 == 0, expanded > 0, expanded <= maxExpandedSize, compressed > 0,
                      local + 30 <= offset, number(local, count: 4) == 0x04034b50 else { throw failure }
                let start = local + 30 + number(local + 26, count: 2) + number(local + 28, count: 2)
                guard start + compressed <= offset else { throw failure }
                if method == 0, compressed == expanded { return data.subdata(in: start..<(start + compressed)) }
                guard method == 8 else { throw failure }
                var output = Data(count: expanded + 1)
                let size = output.withUnsafeMutableBytes { destination in
                    data.withUnsafeBytes { source in
                        compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, expanded + 1,
                                                  source.bindMemory(to: UInt8.self).baseAddress! + start,
                                                  compressed, nil, COMPRESSION_ZLIB)
                    }
                }
                guard size == expanded else { throw failure }
                return output.prefix(size)
            }
            offset = next
        }
        throw failure
    }

    private func number(_ offset: Int, count: Int) -> Int {
        (0..<count).reduce(0) { value, index in value | (Int(data[offset + index]) << (8 * index)) }
    }
}

struct KnowledgeIndex {
    private struct Passage {
        let label: String
        let text: String
        let terms: Set<String>
    }

    private let passages: [Passage]
    private let termCounts: [String: Int]

    init(assistant: AssistantProfile) {
        var materials = assistant.knowledge.prefix(KnowledgeImport.documentLimit).map {
            ("\($0.kind?.rawValue ?? "Reference") · \($0.name)", String($0.text.prefix(KnowledgeImport.textLimit)))
        }
        materials.insert(("User background", String(assistant.background.prefix(KnowledgeImport.textLimit))), at: 0)
        var index = [Passage]()
        var counts = [String: Int]()
        for (label, text) in materials {
            var remaining = text[...]
            while !remaining.isEmpty {
                let window = remaining.prefix(820)
                let end = window.count < 820 ? window.endIndex
                    : (window.lastIndex(where: \.isWhitespace).flatMap { window.distance(from: window.startIndex, to: $0) > 590 ? $0 : nil } ?? window.endIndex)
                let chunk = String(remaining[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                let terms = Self.tokens(chunk)
                if !terms.isEmpty {
                    index.append(Passage(label: label, text: chunk, terms: terms))
                    for term in terms { counts[term, default: 0] += 1 }
                }
                guard end != remaining.endIndex else { break }
                remaining = remaining[remaining.index(end, offsetBy: -100)...]
            }
        }
        passages = index
        termCounts = counts
    }

    func context(for question: String, limit: Int) -> String {
        let query = Self.tokens(question)
        let matches = passages.enumerated().compactMap { index, passage -> (Int, Double)? in
            let matching = passage.terms.intersection(query)
            let score = matching.reduce(0.0) { result, term in
                result + log(1 + Double(passages.count) / Double(termCounts[term, default: 1]))
            }
            return score > 0 ? (index, score) : nil
        }.sorted { a, b in a.1 == b.1 ? a.0 < b.0 : a.1 > b.1 }

        var result = ""
        let ordered = matches.isEmpty ? Array(passages.indices.prefix(2)) : matches.map(\.0)
        for index in ordered.prefix(8) {
            let passage = passages[index]
            let entry = "[\(passage.label)]\n\(passage.text)\n\n"
            let available = limit - result.count
            guard available > 100 else { break }
            result += entry.prefix(available)
        }
        return result
    }

    private static func tokens(_ text: String) -> Set<String> {
        let excluded: Set<String> = ["about", "could", "would", "should", "that", "this", "your", "what", "when",
                                     "where", "with", "which", "have", "tell", "does", "from", "were", "been",
                                     "please", "some", "them", "they", "into", "using", "used"]
        return Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }
            .filter { $0.count > 2 }.map(String.init)).subtracting(excluded)
    }
}
