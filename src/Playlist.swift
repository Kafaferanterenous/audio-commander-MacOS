import Foundation

struct PlaylistEntry: Identifiable, Hashable {
    let url: URL
    var title: String?
    var duration: TimeInterval?
    var id: String { url.path }

    var displayTitle: String {
        let name = url.lastPathComponent
        if let title, !title.isEmpty, title != name { return title }
        return url.deletingPathExtension().lastPathComponent
    }

    var isMissing: Bool {
        !FileManager.default.fileExists(atPath: url.path)
    }

    var isPlayable: Bool {
        AudioFormats.isAudioFile(url.lastPathComponent)
    }
}

struct Playlist: Identifiable {
    let id: URL
    var name: String
    var entries: [PlaylistEntry]

    var playableCount: Int { entries.filter(\.isPlayable).count }
    var missingCount: Int { entries.filter(\.isMissing).count }
    var totalDuration: TimeInterval? {
        let known = entries.compactMap(\.duration).filter { $0 > 0 }
        guard !known.isEmpty else { return nil }
        return known.reduce(0, +)
    }
}

enum M3U {
    /// Decodes as UTF-8 first, then falls back to Windows-1252 because plain
    /// .m3u files are historically written in the local codepage.
    private static func decode(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        let lossy = String(data: data, encoding: .isoLatin1) ?? ""
        return String(decoding: lossy.utf8, as: UTF8.self)
    }

    private static func stripQuotes(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespaces)
        if out.count >= 2, out.hasPrefix("\""), out.hasSuffix("\"") {
            out = String(out.dropFirst().dropLast())
        }
        return out
    }

    /// Splits on LF, CRLF and lone CR. This cannot be done with
    /// `split(whereSeparator: { $0 == "\n" })` because Swift folds "\r\n" into a
    /// SINGLE Character, which would make every Windows playlist one long line.
    private static func lines(of text: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" {
                out.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { out.append(String(current)) }
        return out
    }

    /// Resolves one playlist line to a URL, relative to the playlist location.
    private static func resolve(_ line: String, relativeTo base: URL) -> URL? {
        let raw = stripQuotes(line)
        guard !raw.isEmpty else { return nil }
        // Windows-style absolute paths cannot be mapped onto a Mac volume.
        if raw.count > 2, let colon = raw.firstIndex(of: ":") {
            let afterColon = raw.index(after: colon)
            if raw[raw.startIndex..<colon].allSatisfy(\.isLetter) {
                return URL(fileURLWithPath: raw[afterColon...].replacingOccurrences(of: "\\", with: "/"))
            }
        }
        if raw.hasPrefix("/") { return existingOrSelf(URL(fileURLWithPath: raw)) }
        if raw.lowercased().hasPrefix("file://") {
            if let url = URL(string: raw) { return existingOrSelf(url) }
            return nil
        }
        let direct = base.appendingPathComponent(raw).standardizedFileURL
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        // Some writers percent-encode spaces; try the decoded form too.
        if raw.contains("%"), let decoded = raw.removingPercentEncoding {
            let alt = base.appendingPathComponent(decoded).standardizedFileURL
            if FileManager.default.fileExists(atPath: alt.path) { return alt }
        }
        return direct
    }

    /// Absolute paths may be percent-encoded too, so prefer the decoded form
    /// when it points at a file that actually exists.
    private static func existingOrSelf(_ url: URL) -> URL {
        guard let decoded = url.absoluteString.removingPercentEncoding,
              let alt = URL(string: decoded),
              FileManager.default.fileExists(atPath: alt.path) else { return url }
        return alt
    }

    static func parse(contentsOf url: URL) -> Playlist {
        let name = url.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            return Playlist(id: url, name: name, entries: [])
        }
        var text = decode(data)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let base = url.deletingLastPathComponent()

        var entries: [PlaylistEntry] = []
        var pendingDuration: TimeInterval?
        var pendingTitle: String?

        for rawLine in lines(of: text) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let upper = line.uppercased()
                if upper.hasPrefix("#EXTINF:") {
                    let payload = String(line.dropFirst("#EXTINF:".count))
                    let parts = payload.split(separator: ",", maxSplits: 1,
                                              omittingEmptySubsequences: false)
                    if let first = parts.first {
                        let seconds = Double(first.trimmingCharacters(in: .whitespaces)) ?? -1
                        pendingDuration = seconds > 0 ? seconds : nil
                    }
                    if parts.count > 1 {
                        let title = String(parts[1]).trimmingCharacters(in: .whitespaces)
                        pendingTitle = title.isEmpty ? nil : title
                    }
                }
                // #EXTM3U, #PLAYLIST and unknown directives are ignored.
                continue
            }
            if let resolved = resolve(line, relativeTo: base) {
                entries.append(PlaylistEntry(url: resolved,
                                            title: pendingTitle,
                                            duration: pendingDuration))
            }
            pendingDuration = nil
            pendingTitle = nil
        }
        return Playlist(id: url, name: name, entries: entries)
    }

    /// Writes a portable playlist: paths inside the playlist's own folder tree
    /// are stored relative so the file still works if the whole tree is moved.
    static func write(_ playlist: Playlist, to url: URL) throws {
        var out = "#EXTM3U\n"
        out += "#PLAYLIST:\(playlist.name)\n"
        let base = url.deletingLastPathComponent()
        for entry in playlist.entries {
            let seconds = entry.duration.map { String(Int($0.rounded())) } ?? "-1"
            out += "#EXTINF:\(seconds),\(entry.displayTitle)\n"
            out += pathForWriting(entry.url, relativeTo: base) + "\n"
        }
        try Data(out.utf8).write(to: url, options: .atomic)
    }

    private static func pathForWriting(_ target: URL, relativeTo base: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        guard targetPath.hasPrefix(basePath + "/") else { return targetPath }
        return String(targetPath.dropFirst(basePath.count + 1))
    }
}

@MainActor
final class PlaylistStore: ObservableObject {
    static let shared = PlaylistStore()

    @Published private(set) var playlists: [Playlist] = []
    @Published var selectedID: URL?
    @Published var statusMessage: String?

    var selected: Playlist? {
        guard let selectedID else { return playlists.first }
        return playlists.first { $0.id == selectedID } ?? playlists.first
    }

    var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AudioCommander/Playlists", isDirectory: true)
    }

    private init() {
        load()
    }

    func load() {
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]))?
            .filter { ["m3u", "m3u8"].contains($0.pathExtension.lowercased()) } ?? []
        let loaded = files
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { M3U.parse(contentsOf: $0) }
        playlists = loaded
        if let selectedID, !loaded.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }

    @discardableResult
    func create(named rawName: String) -> Playlist? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var target = dir.appendingPathComponent(sanitized(name) + ".m3u")
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(sanitized(name)) \(counter).m3u")
            counter += 1
        }
        let playlist = Playlist(id: target, name: name, entries: [])
        guard write(playlist) else { return nil }
        load()
        selectedID = target
        return playlist
    }

    /// Copies an existing .m3u into the library so it can be edited and kept.
    @discardableResult
    func importPlaylist(from source: URL) -> Playlist? {
        let parsed = M3U.parse(contentsOf: source)
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = parsed.name.isEmpty ? "Imported" : parsed.name
        var target = dir.appendingPathComponent(sanitized(base) + ".m3u")
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(sanitized(base)) \(counter).m3u")
            counter += 1
        }
        let imported = Playlist(id: target, name: base, entries: parsed.entries)
        guard write(imported) else { return nil }
        load()
        selectedID = target
        return imported
    }

    func append(items: [FileItem], to playlistID: URL) {
        guard var playlist = playlists.first(where: { $0.id == playlistID }) else { return }
        var known = Set(playlist.entries.map(\.url.standardizedFileURL.path))
        for item in items where item.isAudio {
            let path = item.url.standardizedFileURL.path
            guard !known.contains(path) else { continue }
            playlist.entries.append(PlaylistEntry(url: item.url, title: nil,
                                                 duration: item.duration))
            known.insert(path)
        }
        write(playlist)
        load()
        selectedID = playlistID
    }

    func remove(entry: PlaylistEntry, from playlistID: URL) {
        guard var playlist = playlists.first(where: { $0.id == playlistID }) else { return }
        playlist.entries.removeAll { $0.id == entry.id }
        write(playlist)
        load()
        selectedID = playlistID
    }

    func delete(_ playlist: Playlist) {
        try? FileManager.default.removeItem(at: playlist.id)
        if selectedID == playlist.id { selectedID = nil }
        load()
    }

    func rename(_ playlist: Playlist, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let dir = directory
        var target = dir.appendingPathComponent(sanitized(name) + ".m3u")
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path), target != playlist.id {
            target = dir.appendingPathComponent("\(sanitized(name)) \(counter).m3u")
            counter += 1
        }
        let updated = Playlist(id: target, name: name, entries: playlist.entries)
        guard write(updated) else { return }
        if target != playlist.id, FileManager.default.fileExists(atPath: playlist.id.path) {
            try? FileManager.default.removeItem(at: playlist.id)
        }
        load()
        selectedID = target
    }

    @discardableResult
    private func write(_ playlist: Playlist) -> Bool {
        do {
            try M3U.write(playlist, to: playlist.id)
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    private func sanitized(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name.components(separatedBy: illegal).joined(separator: "-")
        return cleaned.isEmpty ? "Playlist" : cleaned
    }

    /// Builds playable items for the player, keeping playlist order.
    func playableItems(from playlist: Playlist) -> (items: [FileItem], startIndex: Int)? {
        let items = playlist.entries
            .filter { $0.isPlayable && !$0.isMissing }
            .map { entry in
                let values = try? entry.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return FileItem(url: entry.url,
                                name: entry.url.lastPathComponent,
                                isDirectory: false,
                                size: Int64(values?.fileSize ?? 0),
                                modified: values?.contentModificationDate,
                                isAudio: true,
                                duration: entry.duration)
            }
        guard !items.isEmpty else { return nil }
        return (items, 0)
    }
}
