import Foundation
import AVFoundation

@MainActor
final class PaneState: ObservableObject {
    let side: String

    @Published var folder: URL {
        didSet {
            guard folder.path != oldValue.path else { return }
            UserDefaults.standard.set(folder.path, forKey: "ac_\(side)_path")
            selectedIDs.removeAll()
            Task { await refresh() }
        }
    }
    @Published private(set) var items: [FileItem] = []
    @Published var sortField: SortField = .name
    @Published var sortAscending = true
    @Published private(set) var totals = PaneTotals()
    @Published private(set) var isLoadingDurations = false
    @Published var statusMessage: String?
    @Published private(set) var recentFolders: [URL] = []
    @Published var selectedIDs: Set<String> = []

    var onPlayRequest: (([FileItem], Int) -> Void)?
    var onAudioToggle: ((FileItem) -> Void)?
    var onActivate: (() -> Void)?

    private var baseItems: [FileItem] = []
    private var durationCache: [String: TimeInterval] = [:]

    init(side: String, fallback: URL) {
        self.side = side
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: "ac_\(side)_path") {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
               isDir.boolValue {
                folder = url
                return
            }
        }
        folder = fallback
    }

    var selectedItems: [FileItem] {
        baseItems.filter { selectedIDs.contains($0.id) }
    }

    func toggleSelection(_ item: FileItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    func navigate(to newFolder: URL) {
        folder = newFolder
    }

    func navigateUp() {
        let parent = folder.deletingLastPathComponent()
        guard parent.path != folder.path else { return }
        folder = parent
    }

    func open(_ item: FileItem) {
        onActivate?()
        if item.isDirectory {
            navigate(to: item.url)
        } else if item.isAudio {
            onAudioToggle?(item)
        } else {
            statusMessage = AppSettings.shared.tf("notAnAudio", item.name)
        }
    }

    func audioPlaylist(startingAt item: FileItem?) -> (items: [FileItem], startIndex: Int)? {
        let audio = baseItems.filter { !$0.isDirectory && $0.isAudio }
        guard !audio.isEmpty else { return nil }
        let index = item.flatMap { target in
            audio.firstIndex { $0.id == target.id }
        } ?? 0
        return (audio, index)
    }

    func refresh() async {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])

            var scanned: [FileItem] = []
            for url in urls {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let isDir = values?.isDirectory ?? false
                scanned.append(FileItem(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: isDir,
                    size: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate,
                    isAudio: !isDir && AudioFormats.isAudioFile(url.lastPathComponent),
                    duration: nil))
            }
            baseItems = AppSettings.shared.showAllFiles
                ? scanned
                : scanned.filter { $0.isDirectory || $0.isAudio }
            statusMessage = nil
            applySort()
            computeTotals()
            rememberRecent()
            await loadDurations()
        } catch {
            statusMessage = error.localizedDescription
            baseItems = []
            items = []
            computeTotals()
        }
    }

    private func rememberRecent() {
        let key = "ac_recent_\(side)"
        var recents = (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .compactMap { URL(string: $0) }
        recents.removeAll { $0.path == folder.path }
        recents.insert(folder, at: 0)
        if recents.count > 6 { recents = Array(recents.prefix(6)) }
        recentFolders = recents
        UserDefaults.standard.set(recents.map { $0.absoluteString }, forKey: key)
    }

    func setSort(_ field: SortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = true
        }
        applySort()
    }

    private func applySort() {
        items = baseItems.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            switch sortField {
            case .name:
                return sortAscending
                    ? a.name.localizedStandardCompare(b.name) == .orderedAscending
                    : a.name.localizedStandardCompare(b.name) == .orderedDescending
            case .size:
                return sortAscending ? a.size < b.size : a.size > b.size
            case .duration:
                let ad = a.duration ?? -1
                let bd = b.duration ?? -1
                return sortAscending ? ad < bd : ad > bd
            }
        }
    }

    private func computeTotals() {
        var t = PaneTotals()
        for item in baseItems {
            if item.isDirectory {
                t.folders += 1
            } else {
                t.files += 1
                t.bytes += item.size
                if item.isAudio { t.songs += 1 }
            }
        }
        totals = t
    }

    private func cacheKey(for item: FileItem) -> String {
        "\(item.url.path)|\(item.size)|\(item.modified?.timeIntervalSince1970 ?? 0)"
    }

    private func loadDurations() async {
        isLoadingDurations = true
        defer { isLoadingDurations = false }

        for item in baseItems {
            applyDuration(path: item.id, seconds: durationCache[cacheKey(for: item)])
        }

        let pending = baseItems.filter { $0.isAudio && durationCache[cacheKey(for: $0)] == nil }
        guard !pending.isEmpty else { return }

        var queue = pending
        await withTaskGroup(of: (FileItem, TimeInterval?).self) { group in
            var inFlight = 0
            while !queue.isEmpty || inFlight > 0 {
                if let item = queue.first, inFlight < 6 {
                    queue.removeFirst()
                    inFlight += 1
                    group.addTask { (item, await Self.readDuration(url: item.url)) }
                } else if let (item, seconds) = await group.next() {
                    inFlight -= 1
                    if let s = seconds { durationCache[cacheKey(for: item)] = s }
                    applyDuration(path: item.id, seconds: seconds)
                    recomputeKnownDuration()
                }
            }
        }
        if sortField == .duration { applySort() }
    }

    private func applyDuration(path: String, seconds: TimeInterval?) {
        guard let index = baseItems.firstIndex(where: { $0.id == path }) else { return }
        baseItems[index].duration = seconds
        if let itemIndex = items.firstIndex(where: { $0.id == path }) {
            items[itemIndex].duration = seconds
        }
    }

    private func recomputeKnownDuration() {
        var sum: TimeInterval = 0
        var count = 0
        for item in baseItems where item.isAudio {
            if let d = item.duration, d > 0 {
                sum += d
                count += 1
            }
        }
        totals.knownDuration = sum
        totals.knownCount = count
    }

    nonisolated private static func readDuration(url: URL) async -> TimeInterval? {
        let ext = url.pathExtension.lowercased()
        switch AudioFormats.route(forExtension: ext) {
        case .embedded:
            return await Task.detached(priority: .utility) {
                PullDecoder.probeDuration(url: url)
            }.value
        case .midi:
            return await Task.detached(priority: .utility) {
                guard let raw = try? Data(contentsOf: url) else { return nil }
                let smf: Data
                if url.pathExtension.lowercased() == "rmi",
                   let r = AudioFormats.unwrapRMID(raw) {
                    smf = r
                } else {
                    smf = raw
                }
                guard let d = AudioFormats.smfDuration(from: smf), d > 0.05 else {
                    return nil
                }
                return d
            }.value
        case .native:
            let asset = AVURLAsset(url: url)
            do {
                let duration = try await asset.load(.duration)
                let seconds = duration.seconds
                guard seconds.isFinite, seconds > 0.05 else { return nil }
                return seconds
            } catch {
                return nil
            }
        }
    }
}
