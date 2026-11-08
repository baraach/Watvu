import Foundation

/// Google Cast v2 wire format, written out by hand so no Google SDK is needed
/// (it has no macOS version). Each message is a 4-byte big-endian length
/// followed by a protobuf `CastMessage`:
///
///     1 protocol_version (varint, 0 = CASTV2_1_0)
///     2 source_id        (string)
///     3 destination_id   (string)
///     4 namespace        (string)
///     5 payload_type     (varint, 0 = STRING)
///     6 payload_utf8     (string, JSON)
struct CastMessage: Equatable {
    var source: String
    var destination: String
    var namespace: String
    var payload: String

    enum Namespace {
        static let connection = "urn:x-cast:com.google.cast.tp.connection"
        static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
        static let receiver = "urn:x-cast:com.google.cast.receiver"
        static let media = "urn:x-cast:com.google.cast.media"
    }

    /// Protobuf bytes (without the length prefix).
    func encoded() -> Data {
        var data = Data()
        data.append(contentsOf: [0x08, 0x00])               // protocol_version = 0
        Self.appendString(2, source, to: &data)
        Self.appendString(3, destination, to: &data)
        Self.appendString(4, namespace, to: &data)
        data.append(contentsOf: [0x28, 0x00])               // payload_type = STRING
        Self.appendString(6, payload, to: &data)
        return data
    }

    /// Length-prefixed frame ready to write to the socket.
    func framed() -> Data {
        let body = encoded()
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    /// Decodes protobuf bytes; unknown fields (e.g. binary payloads) are skipped.
    static func decode(_ data: Data) -> CastMessage? {
        let bytes = [UInt8](data)
        var index = 0
        var message = CastMessage(source: "", destination: "", namespace: "", payload: "")
        while index < bytes.count {
            guard let key = readVarint(bytes, &index) else { return nil }
            let field = Int(key >> 3), wireType = Int(key & 0x7)
            switch wireType {
            case 0:
                guard readVarint(bytes, &index) != nil else { return nil }
            case 2:
                guard let length = readVarint(bytes, &index), index + Int(length) <= bytes.count else { return nil }
                let slice = Data(bytes[index..<index + Int(length)])
                index += Int(length)
                let text = String(data: slice, encoding: .utf8) ?? ""
                switch field {
                case 2: message.source = text
                case 3: message.destination = text
                case 4: message.namespace = text
                case 6: message.payload = text
                default: break
                }
            case 5: index += 4
            case 1: index += 8
            default: return nil
            }
        }
        return message
    }

    /// Length of the frame starting at `data`, if its 4-byte header is there.
    static func frameLength(_ header: Data) -> Int? {
        guard header.count >= 4 else { return nil }
        let b = [UInt8](header.prefix(4))
        return Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
    }

    private static func appendString(_ field: Int, _ value: String, to data: inout Data) {
        let utf8 = Array(value.utf8)
        appendVarint(UInt64(field << 3 | 2), to: &data)
        appendVarint(UInt64(utf8.count), to: &data)
        data.append(contentsOf: utf8)
    }

    static func appendVarint(_ value: UInt64, to data: inout Data) {
        var v = value
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            data.append(byte)
        } while v != 0
    }

    static func readVarint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
        var result: UInt64 = 0, shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }
}

/// Picks the Cast `contentType` for a stream URL.
enum CastContentType {
    static func forURL(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m3u8", "m3u": return "application/x-mpegURL"
        case "mpd": return "application/dash+xml"
        case "mp4", "m4v": return "video/mp4"
        case "webm": return "video/webm"
        case "mkv": return "video/x-matroska"
        case "ts": return "video/mp2t"
        case "mp3": return "audio/mpeg"
        default: return "video/mp4"
        }
    }
}
