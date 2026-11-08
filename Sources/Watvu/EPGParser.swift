import Foundation

struct EPGParseResult {
    var programs: [String: [EPGProgram]]
    /// XMLTV channel id → `<display-name>` values.
    var channelNames: [String: [String]]
}

enum EPGParser {
    static func parse(data: Data) throws -> [String: [EPGProgram]] {
        try parseGuide(data: data).programs
    }

    static func parseGuide(data: Data, timeOffset: Int = 0) throws -> EPGParseResult {
        let delegate = Delegate(timeOffset: timeOffset)
        let parser = XMLParser(data: try gunzipIfNeeded(data))
        parser.delegate = delegate
        guard parser.parse() else {
            throw AppError.file("The EPG file isn’t valid XML.")
        }

        var sorted: [String: [EPGProgram]] = [:]
        for (channel, programs) in delegate.programs {
            sorted[channel] = programs.sorted { $0.start < $1.start }
        }
        return EPGParseResult(programs: sorted, channelNames: delegate.channelNames)
    }

    /// Guides are often served as `.xml.gz`. Foundation's zlib decoder reads
    /// raw DEFLATE, so skip the gzip header (RFC 1952) and 8-byte trailer.
    static func gunzipIfNeeded(_ data: Data) throws -> Data {
        let bytes = [UInt8](data.prefix(4))
        guard bytes.count == 4, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return data }

        let flags = bytes[3]
        let start = data.startIndex
        var offset = 10
        func byte(_ i: Int) -> UInt8 { data[start + i] }
        func skipZeroTerminated() {
            while offset < data.count, byte(offset) != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x04 != 0 { offset += 2 + (Int(byte(offset)) | Int(byte(offset + 1)) << 8) } // FEXTRA
        if flags & 0x08 != 0 { skipZeroTerminated() }   // FNAME
        if flags & 0x10 != 0 { skipZeroTerminated() }   // FCOMMENT
        if flags & 0x02 != 0 { offset += 2 }            // FHCRC
        guard offset < data.count - 8 else { throw AppError.file("The compressed guide is incomplete.") }

        let deflated = data.subdata(in: (start + offset)..<(data.endIndex - 8))
        do {
            return try (deflated as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw AppError.file("The compressed guide couldn't be unpacked.")
        }
    }

    static func epgURL(in text: String) -> String? {
        let firstLines = text.components(separatedBy: .newlines).prefix(8).joined(separator: "\n")
        guard firstLines.lowercased().contains("#extm3u") else { return nil }
        let pattern = #"(?:url-tvg|x-tvg-url)="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(firstLines.startIndex..<firstLines.endIndex, in: firstLines)
        guard let match = regex.firstMatch(in: firstLines, range: range),
              match.numberOfRanges == 2,
              let valueRange = Range(match.range(at: 1), in: firstLines) else { return nil }
        let value = String(firstLines[valueRange]).trimmed
        return value.components(separatedBy: ",").first?.trimmed
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let timeOffset: Int

        var programs: [String: [EPGProgram]] = [:]
        var channelNames: [String: [String]] = [:]

        init(timeOffset: Int = 0) {
            self.timeOffset = timeOffset
        }

        private let formatters: [DateFormatter] = {
            ["yyyyMMddHHmmss Z", "yyyyMMddHHmmssZ", "yyyyMMddHHmmss"].map { format in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = format
                return formatter
            }
        }()

        private var inProgramme = false
        private var inChannel = false
        private var channelElementID: String?
        private var displayNames: [String] = []
        private var channelID: String?
        private var start: Date?
        private var end: Date?
        private var title: String?
        private var subtitle: String?
        private var programmeDescription: String?
        private var category: String?
        private var buffer = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName {
            case "channel":
                inChannel = true
                channelElementID = attributeDict["id"]
                displayNames = []
            case "programme":
                inProgramme = true
                channelID = attributeDict["channel"]
                start = date(attributeDict["start"])?.addingTimeInterval(TimeInterval(timeOffset * 60))
                end = date(attributeDict["stop"])?.addingTimeInterval(TimeInterval(timeOffset * 60))
                title = nil
                subtitle = nil
                programmeDescription = nil
                category = nil
            case "display-name", "title", "sub-title", "desc", "category":
                buffer = ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inProgramme || inChannel else { return }
            buffer += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if inChannel {
                switch elementName {
                case "display-name":
                    let name = buffer.trimmed
                    if !name.isEmpty { displayNames.append(name) }
                case "channel":
                    if let channelElementID {
                        channelNames[channelElementID] = displayNames
                    }
                    inChannel = false
                    channelElementID = nil
                    displayNames = []
                default:
                    break
                }
                buffer = ""
                return
            }

            guard inProgramme else { return }

            switch elementName {
            case "title":
                title = buffer.trimmed
            case "sub-title":
                subtitle = buffer.trimmed
            case "desc":
                programmeDescription = buffer.trimmed
            case "category":
                category = buffer.trimmed
            case "programme":
                if let channelID, let start, let end, let title, !title.isEmpty {
                    let program = EPGProgram(
                        id: "\(channelID)|\(start.timeIntervalSince1970)|\(title)",
                        channelID: channelID,
                        title: title,
                        subtitle: subtitle,
                        description: programmeDescription,
                        category: category,
                        start: start,
                        end: end
                    )
                    programs[channelID, default: []].append(program)
                }
                inProgramme = false
                channelID = nil
                start = nil
                end = nil
                title = nil
                subtitle = nil
                programmeDescription = nil
                category = nil
                buffer = ""
            default:
                break
            }
        }

        private func date(_ value: String?) -> Date? {
            guard let value else { return nil }
            let text = value.trimmed
            for formatter in formatters {
                if let date = formatter.date(from: text) { return date }
            }
            return nil
        }
    }
}

enum EPGMatch {
    private static let ignoredTokens: Set<String> = ["hd", "fhd", "uhd", "4k", "8k", "sd", "hdr", "hevc", "h265"]

    /// Loose channel-name key: case/diacritics folded, punctuation removed,
    /// quality suffixes ignored. "BBC News HD" and "BBC News" both become
    /// "bbc news".
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !ignoredTokens.contains($0) }
            .joined(separator: " ")
    }

    /// Unique display-name match; ambiguous names return nil.
    /// Builds a throwaway index — use `EPGNameIndex` for repeated lookups.
    static func channelID(for name: String, channelNames: [String: [String]]) -> String? {
        EPGNameIndex(channelNames).channelID(for: name)
    }
}

/// Precomputed normalised display-name → XMLTV channel id lookup. Build once
/// per guide; each lookup then only normalises the stream's own name.
struct EPGNameIndex {
    /// nil value = the name maps to more than one channel (ambiguous).
    private var ids: [String: String?] = [:]

    init(_ channelNames: [String: [String]] = [:]) {
        for (id, names) in channelNames {
            for key in Set(names.map(EPGMatch.normalized)) where !key.isEmpty {
                if let existing = ids[key] {
                    if existing != id { ids[key] = .some(nil) }
                } else {
                    ids[key] = .some(id)
                }
            }
        }
    }

    var isEmpty: Bool { ids.isEmpty }

    func channelID(for name: String) -> String? {
        let key = EPGMatch.normalized(name)
        guard !key.isEmpty, let match = ids[key] else { return nil }
        return match
    }
}
