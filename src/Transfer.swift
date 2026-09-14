import Foundation

@MainActor
final class TransferManager: ObservableObject {
    enum Mode { case copy, move, trash }

    struct ProgressState {
        let mode: Mode
        let current: Int
        let total: Int
        let name: String
    }

    @Published private(set) var progress: ProgressState?
    @Published private(set) var showOverlay = false
    @Published private(set) var lastResultMessage: String?

    func perform(mode: Mode, items: [FileItem], destination: URL,
                 settings: AppSettings) async -> (done: Int, errors: Int) {
        guard !items.isEmpty else { return (0, 0) }
        showOverlay = false
        progress = ProgressState(mode: mode, current: 0, total: items.count, name: "")

        let overlayTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !Task.isCancelled && progress != nil {
                showOverlay = true
            }
        }
        defer { overlayTask.cancel() }

        var done = 0
        var errors = 0
        for (index, item) in items.enumerated() {
            progress = ProgressState(mode: mode, current: index + 1,
                                     total: items.count, name: item.name)
            do {
                switch mode {
                case .copy:
                    try FileManager.default.copyItem(at: item.url,
                                                     to: Self.uniquedURL(for: item.url, inFolder: destination))
                case .move:
                    do {
                        try FileManager.default.moveItem(at: item.url,
                                                         to: Self.uniquedURL(for: item.url, inFolder: destination))
                    } catch {
                        try FileManager.default.copyItem(at: item.url,
                                                         to: Self.uniquedURL(for: item.url, inFolder: destination))
                        try FileManager.default.removeItem(at: item.url)
                    }
                case .trash:
                    // Recoverable delete; Trash resolves name clashes itself.
                    try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                }
                done += 1
            } catch {
                errors += 1
            }
        }

        let baseKey = mode == .copy ? "copiedDone" : (mode == .move ? "movedDone" : "trashedDone")
        var message = settings.tf(baseKey, done)
        if errors > 0 {
            message += settings.tf("opErrors", errors)
        }
        lastResultMessage = message
        progress = nil
        showOverlay = false
        return (done, errors)
    }

    static func uniquedURL(for source: URL, inFolder folder: URL) -> URL {
        let ext = source.pathExtension
        let base = ext.isEmpty ? source.lastPathComponent
                               : (source.lastPathComponent as NSString).deletingPathExtension
        var candidate = folder.appendingPathComponent(source.lastPathComponent)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) (\(counter))"
                                   : "\(base) (\(counter)).\(ext)"
            candidate = folder.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }
}
