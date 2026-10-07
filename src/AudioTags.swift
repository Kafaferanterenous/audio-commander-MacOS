import Foundation

/// Editable ID3 tag fields. An empty string means "not set" — on write an empty
/// field removes the frame rather than storing an empty value.
struct AudioTagFields: Equatable {
    var title = ""
    var artist = ""
    var album = ""
    var track = ""
    var year = ""
    var genre = ""
    var comment = ""
}

/// What `ID3.read` hands back: the decoded fields plus whatever else the tag
/// carried that the editor does not expose (album art, TXXX, USLT, ...).
struct AudioTagInfo {
    var fields = AudioTagFields()
    var artwork: Data?
    var hadTag = false
}

/// A parsed ID3v2 tag kept as raw frames so a rewrite can preserve every frame
/// the editor does not manage. Body bytes are already de-unsynchronised and have
/// their group/compression headers stripped.
struct ParsedID3Tag {
    struct Frame {
        var id: String
        var body: Data
    }
    var fields = AudioTagFields()
    var artwork: Data?
    var frames: [Frame] = []
}

/// Pure-Swift ID3v2 reader/writer. No external dependency, matching the project
/// convention of hand-rolled parsers (SMF duration, .m3u). Reads v2.2 / v2.3 /
/// v2.4, writes v2.3 (the most widely compatible revision for the old Android
/// files this app targets), keeps every unmanaged frame, and understands
/// unsynchronisation, extended headers, UTF-16/UTF-8/ISO text and APIC art.
enum ID3 {
    /// Extensions whose tag layer is ID3v2 and therefore safe to rewrite in
    /// place. Other containers (FLAC, MP4, Ogg) must not get an ID3 tag.
    static let editableExtensions: Set<String> = ["mp3", "mp2", "mp1", "mpa"]

    static func isEditable(_ url: URL) -> Bool {
        editableExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Synchsafe integers

    static func synchsafe(_ n: Int) -> [UInt8] {
        [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F),
         UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)]
    }

    static func synchsafeValue(_ bytes: ArraySlice<UInt8>) -> Int {
        var v = 0
        for byte in bytes { v = (v << 7) | Int(byte & 0x7F) }
        return v
    }

    // MARK: - Reading

    /// Reads only the leading ID3v2 tag, avoiding a full file read for what is
    /// usually the first few KB of a multi-MB MP3.
    static func read(url: URL) throws -> AudioTagInfo {
        guard let tag = try tagBytes(url) else { return AudioTagInfo() }
        guard let parsed = parse(tag) else { return AudioTagInfo() }
        return AudioTagInfo(fields: parsed.fields, artwork: parsed.artwork, hadTag: true)
    }

    /// Reads the raw leading ID3v2 bytes (header included) or nil when the file
    /// does not begin with one.
    static func tagBytes(_ url: URL) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: 10), head.count == 10,
              head[0] == 0x49, head[1] == 0x44, head[2] == 0x33
        else { return nil }
        let size = synchsafeValue([UInt8](head)[6..<10])
        let total = 10 + size
        try handle.seek(toOffset: 0)
        return try handle.read(upToCount: total)
    }

    /// Total byte length of the leading ID3v2 tag (header + body + optional
    /// footer), or 0 when there is none. Used to strip the old tag on rewrite.
    static func tagLength(_ bytes: [UInt8]) -> Int {
        guard bytes.count >= 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33
        else { return 0 }
        let major = Int(bytes[3])
        let flags = Int(bytes[5])
        var total = 10 + synchsafeValue(bytes[6..<10])
        // v2.4 footer is included in the size field, but it is not frame data,
        // so callers stripping the tag must still remove it.
        if major == 4, flags & 0x10 != 0, total <= bytes.count { total = min(total, bytes.count) }
        return min(total, bytes.count)
    }

    static func strippingTag(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        let length = tagLength(bytes)
        guard length > 0, length <= bytes.count else { return data }
        return Data(bytes[length...])
    }

    static func parse(_ data: Data) -> ParsedID3Tag? {
        let b = [UInt8](data)
        guard b.count >= 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return nil }
        let major = Int(b[3])
        guard major >= 2, major <= 4 else { return nil }
        let flags = Int(b[5])
        var end = 10 + synchsafeValue(b[6..<10])
        if major == 4, flags & 0x10 != 0 { end -= 10 } // footer
        end = min(end, b.count)
        guard end > 10 else { return nil }
        var body = Array(b[10..<end])
        if flags & 0x80 != 0 { body = deUnsync(body) }

        var pos = 0
        if flags & 0x40 != 0 { // extended header
            if major == 4 {
                guard pos + 4 <= body.count else { return ParsedID3Tag() }
                let ext = synchsafeValue(body[pos..<pos + 4])
                pos += max(ext, 4)
            } else {
                guard pos + 4 <= body.count else { return ParsedID3Tag() }
                let ext = Int(body[pos]) << 24 | Int(body[pos + 1]) << 16
                    | Int(body[pos + 2]) << 8 | Int(body[pos + 3])
                pos += 4 + ext
            }
        }

        var parsed = ParsedID3Tag()
        while pos < body.count {
            if major == 2 {
                guard pos + 6 <= body.count else { break }
                guard let id = ascii(body[pos..<pos + 3]), isFrameID(id) else { break }
                let size = Int(body[pos + 3]) << 16 | Int(body[pos + 4]) << 8 | Int(body[pos + 5])
                pos += 6
                guard size > 0, pos + size <= body.count else { break }
                let frame = Array(body[pos..<pos + size])
                pos += size
                handle(rawID: id, v22: true, data: frame, into: &parsed)
            } else {
                guard pos + 10 <= body.count else { break }
                guard let id = ascii(body[pos..<pos + 4]), isFrameID(id) else { break }
                let size = major == 4
                    ? synchsafeValue(body[pos + 4..<pos + 8])
                    : Int(body[pos + 4]) << 24 | Int(body[pos + 5]) << 16
                        | Int(body[pos + 6]) << 8 | Int(body[pos + 7])
                let second = body[pos + 9]
                pos += 10
                guard size > 0, pos + size <= body.count else { break }
                var frame = Array(body[pos..<pos + size])
                pos += size
                if major == 4 {
                    if second & 0x02 != 0 { frame = deUnsync(frame) }
                    if second & 0x40 != 0, !frame.isEmpty { frame.removeFirst() } // grouping byte
                    if second & 0x01 != 0, frame.count >= 4 { frame.removeFirst(4) } // data length
                    if second & 0x08 != 0 || second & 0x04 != 0 { continue } // compressed/encrypted
                } else if second & 0x80 != 0 || second & 0x40 != 0 {
                    continue // compressed/encrypted
                }
                handle(rawID: id, v22: false, data: frame, into: &parsed)
            }
        }
        return parsed
    }

    // MARK: - Writing

    static func build(fields: AudioTagFields, preserving parsed: ParsedID3Tag?) -> Data {
        var frames: [ParsedID3Tag.Frame] = []
        if let parsed {
            for frame in parsed.frames where !managedIDs.contains(frame.id) {
                frames.append(frame)
            }
        }
        func add(_ id: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            frames.append(ParsedID3Tag.Frame(id: id, body: textBody(trimmed)))
        }
        add("TIT2", fields.title)
        add("TPE1", fields.artist)
        add("TALB", fields.album)
        add("TRCK", fields.track)
        add("TYER", fields.year)
        add("TCON", fields.genre)
        let comment = fields.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !comment.isEmpty {
            frames.append(ParsedID3Tag.Frame(id: "COMM", body: commentBody(comment)))
        }

        var body = Data()
        for frame in frames {
            guard frame.id.count == 4, let idData = frame.id.data(using: .ascii) else { continue }
            body.append(idData)
            let size = UInt32(frame.body.count)
            body.append(contentsOf: [UInt8(size >> 24 & 0xFF), UInt8(size >> 16 & 0xFF),
                                     UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)])
            body.append(contentsOf: [0, 0]) // frame flags
            body.append(frame.body)
        }

        var tag = Data("ID3".utf8)
        tag.append(contentsOf: [3, 0, 0]) // v2.3, revision 0, no flags
        tag.append(contentsOf: synchsafe(body.count))
        tag.append(body)
        return tag
    }

    /// Rewrites `url` with `fields`, keeping every unmanaged frame (album art
    /// included) and the audio payload intact. Written through a sibling temp
    /// file and an atomic replace so a crash cannot truncate the original.
    static func write(fields: AudioTagFields, to url: URL) throws {
        let data = try Data(contentsOf: url)
        let tag = build(fields: fields, preserving: parse(data))
        var out = tag
        out.append(strippingTag(data))

        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).ac-tags-\(UUID().uuidString).tmp")
        try out.write(to: tmp, options: .atomic)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    // MARK: - Frame handling

    private static let managedIDs: Set<String> = [
        "TIT2", "TT2", "TPE1", "TP1", "TALB", "TAL", "TRCK", "TRK",
        "TYER", "TYE", "TDRC", "TCON", "TCO", "COMM", "COM"
    ]

    private static let v22Map: [String: String] = [
        "TT2": "TIT2", "TP1": "TPE1", "TAL": "TALB", "TRK": "TRCK",
        "TYE": "TYER", "TCO": "TCON", "TCM": "TCOM", "COM": "COMM",
        "PIC": "APIC", "TT1": "TIT1", "TP2": "TPE2", "TEN": "TENC",
        "TSS": "TSSE", "TXX": "TXXX", "UFI": "UFID", "ULT": "USLT"
    ]

    private static func handle(rawID: String, v22: Bool, data: [UInt8],
                               into parsed: inout ParsedID3Tag) {
        var id = rawID
        if v22 {
            guard let mapped = v22Map[rawID] else { return }
            id = mapped
        }
        parsed.frames.append(ParsedID3Tag.Frame(id: id, body: Data(data)))

        switch id {
        case "TIT2": parsed.fields.title = firstText(data)
        case "TPE1": parsed.fields.artist = firstText(data)
        case "TALB": parsed.fields.album = firstText(data)
        case "TRCK": parsed.fields.track = firstText(data)
        case "TYER": parsed.fields.year = firstText(data)
        case "TDRC": parsed.fields.year = isoYear(firstText(data))
        case "TCON": parsed.fields.genre = stripGenreIndex(firstText(data))
        case "COMM": parsed.fields.comment = commentText(data)
        case "APIC": if parsed.artwork == nil { parsed.artwork = apicArt(data, v22: v22) }
        default: break
        }
    }

    static func firstText(_ body: [UInt8]) -> String {
        guard let enc = body.first else { return "" }
        let text = decode(enc: Int(enc), bytes: Array(body.dropFirst()))
        return text.components(separatedBy: "\u{0}").first ?? ""
    }

    static func commentText(_ body: [UInt8]) -> String {
        guard body.count > 4, let enc = body.first else { return "" }
        let rest = Array(body[4...]) // skip encoding + 3-byte language
        let text = decode(enc: Int(enc), bytes: rest)
        let parts = text.components(separatedBy: "\u{0}")
        return parts.count > 1 ? parts[1] : (parts.first ?? "")
    }

    /// Old-style numeric genre references like "(17)Rock" become "Rock".
    static func stripGenreIndex(_ value: String) -> String {
        guard value.hasPrefix("("), let close = value.firstIndex(of: ")") else { return value }
        return String(value[value.index(after: close)...])
    }

    /// TDRC is an ISO-8601 timestamp; the editor only exposes the year.
    static func isoYear(_ value: String) -> String {
        let digits = value.prefix { $0.isNumber }
        return digits.isEmpty ? value : String(digits.prefix(4))
    }

    static func decode(enc: Int, bytes: [UInt8]) -> String {
        switch enc {
        case 0:
            return String(bytes: bytes, encoding: .isoLatin1) ?? ""
        case 3:
            return String(bytes: bytes, encoding: .utf8) ?? ""
        case 1:
            if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
                return decodeUTF16(Array(bytes.dropFirst(2)), littleEndian: true)
            }
            if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
                return decodeUTF16(Array(bytes.dropFirst(2)), littleEndian: false)
            }
            return decodeUTF16(bytes, littleEndian: true) // BOM-less: assume LE
        case 2:
            return decodeUTF16(bytes, littleEndian: false)
        default:
            return String(bytes: bytes, encoding: .isoLatin1) ?? ""
        }
    }

    private static func decodeUTF16(_ bytes: [UInt8], littleEndian: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            let u = littleEndian
                ? UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
                : (UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1])
            units.append(u)
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{0}"))
    }

    /// Extracts the embedded image from an APIC (or v2.2 PIC) frame.
    static func apicArt(_ body: [UInt8], v22: Bool) -> Data? {
        guard body.count > 3 else { return nil }
        let enc = Int(body[0])
        var p = 1
        if v22 {
            guard p + 3 <= body.count else { return nil }
            p += 3 // 3-byte "JPG"/"PNG" format
        } else {
            while p < body.count, body[p] != 0 { p += 1 }
            p += 1 // MIME terminator
        }
        guard p < body.count else { return nil }
        p += 1 // picture type
        let step = (enc == 1 || enc == 2) ? 2 : 1
        if step == 2 {
            while p + 1 < body.count, !(body[p] == 0 && body[p + 1] == 0) { p += 2 }
            p += 2
        } else {
            while p < body.count, body[p] != 0 { p += 1 }
            p += 1
        }
        guard p < body.count else { return nil }
        return Data(body[p...])
    }

    // MARK: - Body construction

    private static func isLatin1(_ value: String) -> Bool {
        !value.contains("\u{0}") && value.unicodeScalars.allSatisfy { $0.value <= 0xFF }
    }

    static func textBody(_ value: String) -> Data {
        var d = Data()
        if isLatin1(value) {
            d.append(0)
            d.append(value.data(using: .isoLatin1) ?? Data())
        } else {
            d.append(1)
            appendUTF16(&d, value, withBOM: true)
        }
        return d
    }

    static func commentBody(_ value: String) -> Data {
        var d = Data()
        d.append(isLatin1(value) ? 0 : 1)
        d.append(contentsOf: [0x65, 0x6E, 0x67]) // "eng"
        if isLatin1(value) {
            d.append(0) // empty description terminator
            d.append(value.data(using: .isoLatin1) ?? Data())
        } else {
            d.append(contentsOf: [0, 0]) // UTF-16 empty-description terminator
            appendUTF16(&d, value, withBOM: true)
        }
        return d
    }

    private static func appendUTF16(_ d: inout Data, _ value: String, withBOM: Bool) {
        if withBOM { d.append(contentsOf: [0xFF, 0xFE]) }
        for unit in value.utf16 {
            d.append(UInt8(unit & 0xFF))
            d.append(UInt8(unit >> 8))
        }
    }

    // MARK: - Byte helpers

    static func deUnsync(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            out.append(bytes[i])
            if bytes[i] == 0xFF, i + 1 < bytes.count, bytes[i + 1] == 0x00 {
                i += 2 // drop the inserted zero after 0xFF
            } else {
                i += 1
            }
        }
        return out
    }

    static func ascii(_ bytes: ArraySlice<UInt8>) -> String? {
        String(bytes: bytes, encoding: .ascii)
    }

    static func isFrameID(_ id: String) -> Bool {
        guard id.count == 3 || id.count == 4 else { return false }
        return id.allSatisfy { ($0.isUppercase && $0.isLetter) || $0.isNumber }
    }
}
