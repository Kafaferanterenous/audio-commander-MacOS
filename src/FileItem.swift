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
        "flac", "caf",
        "amr", "3gp", "3gpp", "3g2", "3ga",
        "wma", "ape", "wv", "dsf", "dff"
    ]
    /// Formats handled by the embedded C decoders (DUMB + stb_vorbis + VOC).
    static let embeddedExtensions: Set<String> = [
        "ogg", "oga",
        "mod", "s3m", "xm", "it",
        "669", "amf", "ams", "dsm", "far", "mtm", "okt", "psm", "ptm", "stm", "ult",
        "voc"
    ]
    /// MIDI (native AVMIDIPlayer with system sound bank).
    static let midiExtensions: Set<String> = ["mid", "midi"]

    static let extensions: Set<String> =
        nativeExtensions.union(embeddedExtensions).union(midiExtensions)

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
