import Foundation

struct FileItem: Identifiable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?
    let isAudio: Bool
    var duration: TimeInterval?
    var id: String { url.path }
}

enum AudioFormats {
    /// Formats AVAudioFile/AVPlayer handle natively.
    static let nativeExtensions: Set<String> = [
        "wav", "wave", "aif", "aiff", "aifc",
        "mp3", "mp2", "m4a", "m4b", "mp4", "aac", "adts", "alac",
        "flac", "caf", "au", "snd",
        "opus",
        "amr", "3gp", "3gpp", "3g2", "3ga",
        "ac3", "ec3", "eac3"
    ]
    /// Audio formats the app recognizes but cannot decode yet.
    /// Kept out of `extensions` so they never show as playable.
    static let unsupportedExtensions: Set<String> = [
        "wma", "ape"
    ]
    /// Formats handled by the embedded C decoders (DUMB + stb_vorbis + VOC + WavPack + libFLAC + DSD).
    static let embeddedExtensions: Set<String> = [
        "ogg", "oga",
        "mod", "s3m", "xm", "it",
        "669", "amf", "ams", "dsm", "far", "mtm", "okt", "psm", "ptm", "stm", "ult",
        "voc",
        "wv", "dsf", "dff"
    ]
    /// MIDI (native AVMIDIPlayer with system sound bank).
    static let midiExtensions: Set<String> = ["mid", "midi", "rmi"]

    /// RMID is a Standard MIDI File wrapped in a RIFF container; AVMIDIPlayer
    /// cannot open the .rmi shell directly, so extract the embedded SMF.
    static func unwrapRMID(_ fileData: Data) -> Data? {
        let bytes = [UInt8](fileData)
        guard bytes.count > 12,
              String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "RMID"
        else { return nil }
        var off = 12
        while off + 8 <= bytes.count {
            let id = String(bytes: bytes[off..<off + 4], encoding: .ascii)
            let size = Int(bytes[off + 4]) | (Int(bytes[off + 5]) << 8)
                | (Int(bytes[off + 6]) << 16) | (Int(bytes[off + 7]) << 24)
            if id == "data" {
                guard off + 8 + size <= bytes.count else { return nil }
                return Data(bytes[off + 8..<off + 8 + size])
            }
            off += 8 + size + (size & 1) // RIFF chunks are word-aligned
        }
        return nil
    }

    /// Deterministic SMF duration probe (seconds) without any audio framework.
    /// Parses the MThd header, all tempo metas (FF 51) across tracks and the
    /// overall end tick, then integrates tempo segments. nil on any malformed
    /// structure or SMPTE-time division (rare).
    static func smfDuration(from data: Data) -> TimeInterval? {
        let b = [UInt8](data)
        guard b.count >= 14,
              b[0] == 0x4D, b[1] == 0x54, b[2] == 0x68, b[3] == 0x64,
              b[4] == 0, b[5] == 0, b[6] == 0, b[7] == 6
        else { return nil }
        let division = Int(b[12]) << 8 | Int(b[13])
        guard division > 0, division & 0x8000 == 0 else { return nil } // ticks/beat only
        let tpb = division & 0x7FFF

        func vlq(_ p: Int, _ end: Int, _ n: inout Int) -> UInt32? {
            var v: UInt32 = 0
            var i = p
            n = 0
            while i < end && n < 4 {
                let d = b[i]
                i += 1
                n += 1
                v = (v << 7) | UInt32(d & 0x7F)
                if d & 0x80 == 0 { return v }
            }
            return nil
        }

        var tempos: [(tick: UInt64, usec: UInt32)] = []
        var globalEnd: UInt64 = 0
        var pos = 14
        while pos + 8 <= b.count {
            guard b[pos] == 0x4D, b[pos + 1] == 0x54,
                  b[pos + 2] == 0x72, b[pos + 3] == 0x6B
            else { return nil }
            let tlen = Int(UInt32(b[pos + 4]) << 24 | UInt32(b[pos + 5]) << 16
                | UInt32(b[pos + 6]) << 8 | UInt32(b[pos + 7]))
            pos += 8
            guard tlen >= 0, pos + tlen <= b.count else { return nil }
            let trackEnd = pos + tlen
            var tick: UInt64 = 0
            var lastTick: UInt64 = 0
            var seenEndMeta = false
            var prevStatus = 0
            var p = pos
            while p < trackEnd {
                var n = 0
                guard let delta = vlq(p, trackEnd, &n) else { return nil }
                p += n
                tick &+= UInt64(delta)
                guard p < trackEnd else { return nil }
                var status = Int(b[p])
                if status & 0x80 == 0 {
                    guard prevStatus != 0 else { return nil } // bare running status
                    status = prevStatus
                } else {
                    prevStatus = status
                    p += 1
                }
                if status == 0xFF {
                    guard p < trackEnd else { return nil }
                    let mtype = Int(b[p])
                    p += 1
                    guard let ml = vlq(p, trackEnd, &n) else { return nil }
                    p += n
                    guard p + Int(ml) <= trackEnd else { return nil }
                    if mtype == 0x51 && ml >= 3 {
                        let usec = UInt32(b[p]) << 16 | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2])
                        tempos.append((tick, usec))
                    }
                    if mtype == 0x2F { seenEndMeta = true }
                    p += Int(ml)
                } else if status == 0xF0 || status == 0xF7 {
                    guard let l = vlq(p, trackEnd, &n) else { return nil }
                    p += n
                    guard p + Int(l) <= trackEnd else { return nil }
                    p += Int(l)
                } else {
                    var dataLen = 1
                    switch status & 0xF0 {
                    case 0xC0, 0xD0: dataLen = 1
                    default: dataLen = 2
                    }
                    guard p + dataLen <= trackEnd else { return nil }
                    p += dataLen
                }
                lastTick = tick
            }
            if seenEndMeta { globalEnd = max(globalEnd, tick) }
            else { globalEnd = max(globalEnd, lastTick) }
            pos = trackEnd
        }
        guard globalEnd > 0 else { return nil }

        var curUsec: UInt32 = 500_000
        var atTick: UInt64 = 0
        var seconds: Double = 0
        for t in tempos.sorted(by: { $0.tick < $1.tick }) {
            guard t.tick >= atTick else { continue }
            seconds += Double(t.tick - atTick) * Double(curUsec)
                / Double(tpb) / 1_000_000
            atTick = t.tick
            curUsec = t.usec
        }
        seconds += Double(globalEnd > atTick ? globalEnd - atTick : 0) * Double(curUsec)
            / Double(tpb) / 1_000_000
        return seconds > 0 && seconds.isFinite ? seconds : nil
    }

    static let extensions: Set<String> =
        nativeExtensions.union(embeddedExtensions).union(midiExtensions)

    /// Human-readable line for the Settings sheet: formats that actually play.
    static let playableFormatsText: String = {
        func spaced(_ set: Set<String>) -> String {
            set.sorted().joined(separator: " ")
        }
        return """
        Native (CoreAudio): \(spaced(nativeExtensions))
        Vorbis / trackers / lossless (DUMB + stb + WavPack + libFLAC): \(spaced(embeddedExtensions))
        MIDI: \(spaced(midiExtensions))
        """
    }()

    /// Human-readable line for the Settings sheet: formats recognized by the
    /// app or ecosystem but not decoded yet, and which could be added.
    static let nonImplementedFormatsText: String =
        "WMA (Windows Media), APE (Monkey's), DSD (DSF/DFF), DTS"

    enum Route { case native, embedded, midi }

    static func route(forExtension ext: String) -> Route {
        let e = ext.lowercased()
        if midiExtensions.contains(e) { return .midi }
        if embeddedExtensions.contains(e) { return .embedded }
        return .native
    }

    static func isAudioFile(_ name: String) -> Bool {
        extensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Playlist files are not audio, but they are clickable so a playlist can
    /// be opened straight from a pane.
    static let playlistExtensions: Set<String> = ["m3u", "m3u8"]

    static func isPlaylistFile(_ name: String) -> Bool {
        playlistExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    static func sizeText(_ bytes: Int64, isDirectory: Bool) -> String {
        if isDirectory { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func durationText(_ duration: TimeInterval?) -> String {
        guard let d = duration, d.isFinite, d > 0 else { return "—" }
        let total = Int(d.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

enum SortField: String, CaseIterable, Identifiable {
    case name = "Name"
    case size = "Size"
    case duration = "Duration"
    var id: String { rawValue }
}

struct PaneTotals {
    var folders = 0
    var files = 0
    var songs = 0
    var bytes: Int64 = 0
    var knownDuration: TimeInterval = 0
    var knownCount = 0
}
