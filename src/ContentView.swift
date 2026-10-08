import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Function-key equivalents (F1-F12 live in Unicode's private-use area).
extension KeyEquivalent {
    init(functionKey code: Int) {
        self = KeyEquivalent(Character(UnicodeScalar(UInt32(code))!))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// Strong-ish handle to the real main window. `NSApp.windows.first` is NOT
    /// safe once the mini player (#13) is a floating panel: `NSApp.windows` is
    /// front-to-back ordered, so a visible mini player would be "first" and the
    /// main window's frame would be saved from the wrong window.
    private static weak var cachedMainWindow: NSWindow?

    static var current: NSWindow? {
        if let cached = cachedMainWindow { return cached }
        let found = NSApp.windows.first { win in
            guard !(win is NSPanel) else { return false }
            guard win.identifier != MiniPlayerController.panelID else { return false }
            return win.sheetParent == nil
        }
        cachedMainWindow = found
        return found
    }

    /// Brings the main window back: orders it front if it still exists,
    /// otherwise re-activates the app so AppKit/SwiftUI reopens the WindowGroup.
    static func revealMainWindow() {
        if let win = current {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// The mini player keeps the app (and playback) alive once the main window
    /// is closed; the app quits only when the LAST window goes away.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let miniOpen = MainActor.assumeIsolated { MiniPlayerController.shared.isOpen }
        return !miniOpen
    }

    /// Reopening from the Dock with only the mini player up must bring the main
    /// window back (false = let AppKit/SwiftUI handle the reopen).
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { NowPlaying.clear() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { NowPlaying.installCommands() }
        DispatchQueue.main.async { [weak self] in
            guard let self, let win = Self.current else { return }
            win.delegate = self
            win.title = "AudioCommander"
            self.refreshWindowFrame(win)
            // #13: bring the mini player back if it was left open.
            MainActor.assumeIsolated { MiniPlayerController.shared.restoreIfOpen() }
        }
    }

    func windowDidMove(_ notification: Notification) { scheduleSaveWindowFrame() }
    func windowDidResize(_ notification: Notification) { scheduleSaveWindowFrame() }
    func windowWillClose(_ notification: Notification) { saveWindowFrame() }

    private func refreshWindowFrame(_ win: NSWindow) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "ac_win_frame") == nil,
           defaults.object(forKey: "ac_open_full") == nil || defaults.bool(forKey: "ac_open_full") {
            if let visible = NSScreen.main?.visibleFrame {
                win.setFrame(visible, display: false)
                saveWindowFrame()
                return
            }
        }
        guard let stored = defaults.string(forKey: "ac_win_frame"),
              let visible = NSScreen.main?.visibleFrame else { return }
        let r = NSRectFromString(stored)
        guard r.width >= 600, r.height >= 400 else { return }
        let x = min(max(r.midX - r.width / 2, visible.minX),
                    visible.maxX - r.width)
        let y = min(max(r.midY - r.height / 2, visible.minY),
                    visible.maxY - r.height)
        win.setFrame(NSRect(x: x, y: y, width: r.width, height: r.height),
                     display: false)
    }

    private func scheduleSaveWindowFrame() {
        NSObject.cancelPreviousPerformRequests(withTarget: self,
                                               selector: #selector(saveWindowFrame),
                                               object: nil)
        perform(#selector(saveWindowFrame), with: nil, afterDelay: 0.4)
    }

    @objc private func saveWindowFrame() {
        guard let win = Self.current else { return }
        UserDefaults.standard.set(NSStringFromRect(win.frame), forKey: "ac_win_frame")
    }
}

@main
struct AudioCommanderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 640)
                .environmentObject(AppSettings.shared)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 740)
        .commands {
            CommandGroup(replacing: .systemServices) { }
            CommandGroup(after: .appInfo) {
                Button("Settings…") {
                    AppSettings.shared.requestSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // Linux-spec parity: F5 copies / F6 moves the ACTIVE pane's
            // selection to the other side. F-keys via their function-key
            // Unicode scalars (.function modifier is deprecated).
            CommandGroup(after: .toolbar) {
                Button(AppSettings.shared.t("copyToOther")) {
                    CommanderStore.shared.copyActive()
                }
                .keyboardShortcut(KeyEquivalent(functionKey: NSF5FunctionKey), modifiers: [])
                Button(AppSettings.shared.t("moveToOther")) {
                    CommanderStore.shared.moveActive()
                }
                .keyboardShortcut(KeyEquivalent(functionKey: NSF6FunctionKey), modifiers: [])
                Button(AppSettings.shared.t("trashSel")) {
                    CommanderStore.shared.trashActive()
                }
                .keyboardShortcut(KeyEquivalent.delete, modifiers: [.command])
                // #13 Mini player (floating window, lives outside the drawer).
                Button(AppSettings.shared.t("miniPlayer")) {
                    MiniPlayerController.shared.toggle()
                }
                .keyboardShortcut("m", modifiers: [.command, .option])
            }
        }
    }
}

@MainActor
final class CommanderStore: ObservableObject {
    static let shared = CommanderStore()

    @Published var activeSide = "left"
    @Published private(set) var left: PaneState
    @Published private(set) var right: PaneState
    @Published var drawerOpen = false
    /// Which flyout tab is showing. Lives here rather than in the drawer's own
    /// state so the gear icon and the Settings… menu item can select a tab.
    @Published var drawerTab: DrawerTab = .library
    let player = PlayerState()
    /// #16 spectrum analyser. Shared singleton so PlayerState's engine taps and
    /// the Effects tab read the same object without threading a reference
    /// through CommanderStore's initialiser.
    let spectrum = SpectrumAnalyzer.shared
    let transfer = TransferManager()
    let playlists = PlaylistStore.shared
    /// #21 metadata editor state. Kept on the store so in-progress edits survive
    /// switching drawer tabs.
    let tagEditor = TagEditorModel()

    var activePane: PaneState { activeSide == "right" ? right : left }

    /// The file the metadata editor shows: the single selection in the active
    /// pane if there is exactly one, otherwise the track that is playing.
    var tagTarget: FileItem? {
        let selected = activePane.selectedItems
        if selected.count == 1 { return selected[0] }
        return player.currentTrack
    }

    private init() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first ?? home
        left = PaneState(side: "left", fallback: home)
        right = PaneState(side: "right", fallback: music)

        for (captured, pane) in [("left", left), ("right", right)] {
            pane.onPlayRequest = { [weak self] items, index in
                self?.player.playQueue(items: items, index: index,
                                       paneLabel: AppSettings.shared.t(captured))
            }
            pane.onAudioToggle = { [weak self] item in
                self?.handleAudioClick(item, in: pane)
            }
            pane.onActivate = { [weak self, weak pane] in
                guard let pane = pane else { return }
                self?.activeSide = pane.side
            }
            pane.onPlaylistOpen = { [weak self] url in
                self?.openPlaylistFile(url)
            }
        }
    }

    /// A playlist clicked in a pane is copied into the library so it can be
    /// edited here; the original file on disk is never modified.
    func openPlaylistFile(_ url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        if let existing = playlists.playlists.first(where: {
            $0.entries.contains { $0.url == url } && $0.name == name
        }) ?? playlists.playlists.first(where: {
            $0.id.lastPathComponent == url.lastPathComponent
        }) {
            playlists.selectedID = existing.id
        } else if let imported = playlists.importPlaylist(from: url) {
            playlists.statusMessage = AppSettings.shared.tf("playlistImported",
                                                           imported.name, imported.entries.count)
        } else {
            playlists.statusMessage = AppSettings.shared.tf("playlistBad", url.lastPathComponent)
        }
        drawerOpen = true
    }

    /// Starts playback of a library playlist, honouring shuffle and repeat.
    func play(_ playlist: Playlist) {
        guard let payload = playlists.playableItems(from: playlist) else {
            playlists.statusMessage = AppSettings.shared.t("playlistNoPlayable")
            return
        }
        player.playQueue(items: payload.items, index: payload.startIndex,
                         paneLabel: playlist.name)
        drawerOpen = false
    }

    func addSelection(to playlist: Playlist) {
        let items = activePane.selectedItems
        guard !items.isEmpty else {
            activePane.statusMessage = AppSettings.shared.t("selectFirst")
            return
        }
        playlists.append(items: items, to: playlist.id)
        playlists.statusMessage = AppSettings.shared.tf("playlistAdded", items.count, playlist.name)
    }

    // Single-click behavior: click plays; click again stops;
    // clicking a different file switches playback to it.
    private func handleAudioClick(_ item: FileItem, in pane: PaneState) {
        if player.currentTrack?.id == item.id {
            player.stopPlayback()
            return
        }
        guard let playlist = pane.audioPlaylist(startingAt: item) else { return }
        player.playQueue(items: playlist.items, index: playlist.startIndex,
                         paneLabel: AppSettings.shared.t(pane.side))
    }

    /// Finder drag & drop into a pane (#12): copies every dropped item
    /// (whole folders recurse) into that pane's current folder, then rescans.
    /// Name clashes become "name (2).ext" and the result shows in the pane's
    /// summary bar, mirroring the toolbar copy behaviour.
    func dropIn(_ urls: [URL], pane: PaneState) async {
        let items = PaneState.fileItems(from: urls)
        guard !items.isEmpty else {
            pane.statusMessage = AppSettings.shared.t("dropNothing")
            return
        }
        _ = await transfer.perform(mode: .copy, items: items,
                                   destination: pane.folder, settings: AppSettings.shared)
        pane.selectedIDs.removeAll()
        await pane.refresh()
        pane.statusMessage = transfer.lastResultMessage
    }

    func runTransfer(mode: TransferManager.Mode, source: PaneState) {
        let destination = source === left ? right : left
        let items = source.selectedItems
        guard !items.isEmpty else {
            source.statusMessage = AppSettings.shared.t("selectFirst")
            return
        }
        Task {
            _ = await transfer.perform(mode: mode, items: items,
                                       destination: destination.folder,
                                       settings: AppSettings.shared)
            source.selectedIDs.removeAll()
            await source.refresh()
            await destination.refresh()
            // refresh() clears statusMessage, so set the result afterwards.
            source.statusMessage = transfer.lastResultMessage
        }
    }

    func copyActive() { runTransfer(mode: .copy, source: activePane) }
    func moveActive() { runTransfer(mode: .move, source: activePane) }
    func trashActive() { trashSelection(in: activePane) }

    func trashSelection(in source: PaneState) {
        let items = source.selectedItems
        guard !items.isEmpty else {
            source.statusMessage = AppSettings.shared.t("selectFirst")
            return
        }
        // Porting rule: stop playback cleanly before deleting the track.
        if let current = player.currentTrack,
           items.contains(where: { $0.id == current.id }) {
            player.stopPlayback()
        }
        Task {
            _ = await transfer.perform(mode: .trash, items: items,
                                       destination: source.folder,
                                       settings: AppSettings.shared)
            source.selectedIDs.removeAll()
            await source.refresh()
            // refresh() clears statusMessage, so set the result afterwards.
            source.statusMessage = transfer.lastResultMessage
        }
    }

    func swapPanes() {
        let leftFolder = left.folder
        let rightFolder = right.folder
        left.navigate(to: rightFolder)
        right.navigate(to: leftFolder)
    }

    func initialLoad() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.left.refresh() }
            group.addTask { await self.right.refresh() }
        }
    }
}

struct ContentView: View {
    @ObservedObject private var store = CommanderStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var mini = MiniPlayerController.shared
    @FocusState private var focusedPane: PaneSide?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PaneView(pane: store.left, side: .leftPane,
                         focusedPane: $focusedPane,
                         onCopySelection: { store.runTransfer(mode: .copy, source: store.left) },
                         onMoveSelection: { store.runTransfer(mode: .move, source: store.left) },
                         onTrashSelection: { store.trashSelection(in: store.left) })
                    .frame(maxWidth: .infinity)

                centerDivider

                PaneView(pane: store.right, side: .rightPane,
                         focusedPane: $focusedPane,
                         onCopySelection: { store.runTransfer(mode: .copy, source: store.right) },
                         onMoveSelection: { store.runTransfer(mode: .move, source: store.right) },
                         onTrashSelection: { store.trashSelection(in: store.right) })
                    .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .top) {
                topButtons
            }
            Divider().overlay(settings.palette.divider)
            PlaybackBar(player: store.player)
        }
        .overlay(alignment: .trailing) {
            if store.drawerOpen {
                InspectorDrawer(store: store, isOpen: $store.drawerOpen)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: store.drawerOpen)
        .overlay {
            if let progress = store.transfer.progress {
                TransferOverlay(transfer: store.transfer, progress: progress)
            }
        }
        .onChange(of: settings.settingsRequest) { _ in
            // Settings… from the menu bar opens the flyout on the same tab the
            // gear does, so there is one place settings live.
            store.drawerOpen = true
            store.drawerTab = .settings
        }
        .onChange(of: settings.showAllFiles) { _ in
            Task {
                await store.left.refresh()
                await store.right.refresh()
            }
        }
        .onChange(of: focusedPane) { pane in
            if let side = pane {
                store.activeSide = side == .leftPane ? "left" : "right"
            }
        }
        .background(
            LinearGradient(colors: [settings.palette.bgTop, settings.palette.bgBottom],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        )
        .preferredColorScheme(settings.palette.colorScheme)
        .task { await store.initialLoad() }
    }

    // Visible center divider: themed base line + bright accent core.
    private var centerDivider: some View {
        ZStack {
            Rectangle()
                .fill(settings.palette.divider)
                .frame(width: 5)
            Rectangle()
                .fill(LinearGradient(colors: [settings.palette.accent.opacity(0.85),
                                              settings.palette.accent.opacity(0.35)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 2)
                .shadow(color: settings.palette.accent.opacity(0.45),
                        radius: 2, x: 0, y: 0)
        }
        .frame(maxHeight: .infinity)
    }

    /// Overlays the top of the panes. The pane-side toggle is gone: it sat over
    /// the left pane's "Left" header and, now that the gear opens the flyout,
    /// there was nothing left for it to do. The gear toggles the flyout instead,
    /// so the top strip carries only the mini player and the gear on the right.
    private var topButtons: some View {
        ZStack {
            HStack {
                Spacer()
                Button {
                    mini.toggle()
                } label: {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 13).weight(.medium))
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                        .foregroundStyle(mini.isOpen ? settings.palette.accent : .primary)
                        .help(settings.t("miniPlayer"))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                Button {
                    // The gear is the flyout's front door: it opens the drawer on
                    // the Settings tab, and closes it again when that tab is
                    // already up. It is the only toggle now, so it has to both
                    // open and close.
                    if store.drawerOpen && store.drawerTab == .settings {
                        store.drawerOpen = false
                    } else {
                        store.drawerOpen = true
                        store.drawerTab = .settings
                    }
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13).weight(.medium))
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                        .foregroundStyle(store.drawerOpen ? settings.palette.accent : .primary)
                        .help(settings.t("settings"))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 12)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
            Button {
                store.swapPanes()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption.weight(.bold))
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
                    .help(settings.t("swapPanes"))
            }
            .buttonStyle(.plain)
            .offset(y: 26)
            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
        }
    }
}

// MARK: - Inspector drawer

enum DrawerTab: String, CaseIterable, Identifiable {
    case library, effects, utilities, settings
    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .library: return "drawerLibrary"
        case .effects: return "drawerEffects"
        case .utilities: return "drawerUtilities"
        case .settings: return "settings"
        }
    }
}

/// Right-side overlay drawer (Xcode Inspector style). It floats OVER the right
/// pane so the two panes never reflow, each tab scrolls on its own, and a
/// single toggle opens/closes it.
struct InspectorDrawer: View {
    @ObservedObject var store: CommanderStore
    @EnvironmentObject private var settings: AppSettings
    @Binding var isOpen: Bool
    @State private var newName = ""
    @State private var isNaming = false
    @State private var isRenaming = false
    @State private var pendingDelete: Playlist?

    private var playlists: PlaylistStore { store.playlists }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(settings.palette.divider)
            Picker("", selection: $store.drawerTab) {
                ForEach(DrawerTab.allCases) { t in
                    Text(settings.t(t.titleKey)).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 10)

            switch store.drawerTab {
            case .library: libraryTab
            case .effects: effectsTab
            case .utilities: utilitiesTab
            case .settings: settingsTab
            }

            if let status = playlists.statusMessage {
                Text(status)
                    .font(settings.scaled(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 360)
        .background(LinearGradient(colors: [settings.palette.bgTop, settings.palette.bgBottom],
                                   startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .leading) {
            Rectangle().fill(settings.palette.divider).frame(width: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 12, x: -4, y: 0)
        .confirmationDialog(
            settings.t("deletePlaylist"),
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(settings.t("deletePlaylist"), role: .destructive) {
                if let playlist = pendingDelete { playlists.delete(playlist) }
                pendingDelete = nil
            }
            Button(settings.t("close"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(settings.tf("deletePlaylistConfirm", pendingDelete?.name ?? ""))
        }
    }

    private var header: some View {
        HStack {
            Text(settings.t("drawerTitle"))
                .font(settings.scaled(13).weight(.semibold))
            Spacer()
            Picker("", selection: $store.drawerTab) {
                ForEach(DrawerTab.allCases) { t in
                    Text(settings.t(t.titleKey)).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            Spacer()
            Button {
                isOpen = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(settings.t("close"))
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: Library

    private var libraryTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button {
                    isNaming = true
                } label: {
                    Label(settings.t("newPlaylist"), systemImage: "plus")
                        .font(settings.scaled(11))
                }
                .buttonStyle(.bordered)

                Button {
                    importPlaylist()
                } label: {
                    Label(settings.t("importM3U"), systemImage: "square.and.arrow.down")
                        .font(settings.scaled(11))
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding(.horizontal, 12)

            if isNaming {
                HStack(spacing: 6) {
                    TextField(settings.t("playlistName"), text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .font(settings.scaled(11))
                        .onSubmit(commitNew)
                    Button(action: commitNew) {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.borderless)
                    Button {
                        isNaming = false
                        newName = ""
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
            }

            if playlists.playlists.isEmpty {
                placeholder(settings.t("noPlaylists"))
            } else {
                playlistList
                Divider().overlay(settings.palette.divider)
                entryList
                actions
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func commitNew() {
        if playlists.create(named: newName) != nil {
            newName = ""
            isNaming = false
        }
    }

    private var playlistList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(playlists.playlists) { playlist in
                    let isSelected = playlist.id == playlists.selected?.id
                    HStack(spacing: 6) {
                        Image(systemName: isSelected ? "music.note.list" : "music.note.list")
                            .foregroundStyle(isSelected ? settings.palette.accent : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(playlist.name)
                                .font(settings.scaled(12).weight(isSelected ? .semibold : .regular))
                                .lineLimit(1)
                            Text(subtitle(for: playlist))
                                .font(settings.scaled(9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            pendingDelete = playlist
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(settings.t("deletePlaylist"))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(isSelected ? settings.palette.accent.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        playlists.selectedID = playlist.id
                        isRenaming = false
                    }
                    .contextMenu {
                        Button(settings.t("play")) { store.play(playlist) }
                        Button(settings.t("renamePlaylist")) {
                            newName = playlist.name
                            isRenaming = true
                            isNaming = false
                        }
                        Button(settings.t("revealInFinder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([playlist.id])
                        }
                        Divider()
                        Button(settings.t("deletePlaylist"), role: .destructive) {
                            pendingDelete = playlist
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(maxHeight: 150)
    }

    private func subtitle(for playlist: Playlist) -> String {
        var parts = [settings.tf("audioN", playlist.playableCount)]
        if let total = playlist.totalDuration {
            parts.append(AudioFormats.durationText(total))
        }
        if playlist.missingCount > 0 {
            parts.append(settings.tf("missingN", playlist.missingCount))
        }
        return parts.joined(separator: " · ")
    }

    private var entryList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if isRenaming {
                    HStack(spacing: 6) {
                        TextField(settings.t("playlistName"), text: $newName)
                            .textFieldStyle(.roundedBorder)
                            .font(settings.scaled(11))
                            .onSubmit {
                                if let playlist = playlists.selected {
                                    playlists.rename(playlist, to: newName)
                                }
                                isRenaming = false
                            }
                        Button {
                            if let playlist = playlists.selected {
                                playlists.rename(playlist, to: newName)
                            }
                            isRenaming = false
                        } label: {
                            Image(systemName: "checkmark")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
                }

                if let playlist = playlists.selected {
                    if playlist.entries.isEmpty {
                        Text(settings.t("playlistEmpty"))
                            .font(settings.scaled(11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(Array(playlist.entries.enumerated()), id: \.element.id) { index, entry in
                            entryRow(index: index, entry: entry, playlist: playlist)
                        }
                    }
                } else {
                    Text(settings.t("selectPlaylistPrompt"))
                        .font(settings.scaled(11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func entryRow(index: Int, entry: PlaylistEntry, playlist: Playlist) -> some View {
        let isCurrent = store.player.currentTrack?.id == entry.id
        let playable = entry.isPlayable && !entry.isMissing
        return HStack(spacing: 6) {
            Text("\(index + 1)")
                .font(settings.scaled(9).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayTitle)
                    .font(settings.scaled(11).weight(isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .strikethrough(entry.isMissing, color: .secondary)
                HStack(spacing: 4) {
                    Text(AudioFormats.durationText(entry.duration))
                    if entry.isMissing {
                        Text(settings.t("missingFile"))
                            .foregroundStyle(.red.opacity(0.85))
                    } else if !entry.isPlayable {
                        Text(settings.t("unsupportedFile"))
                            .foregroundStyle(.orange.opacity(0.9))
                    }
                }
                .font(settings.scaled(9))
                .foregroundStyle(.secondary)
            }
            Spacer()
            if playable {
                Button {
                    playEntry(entry, in: playlist)
                } label: {
                    Image(systemName: "play.fill").font(.system(size: 9))
                }
                .buttonStyle(.borderless)
                .help(settings.t("playFromHere"))
            }
            Button {
                playlists.remove(entry: entry, from: playlist.id)
            } label: {
                Image(systemName: "minus.circle").font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(settings.t("removeEntry"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(isCurrent ? settings.palette.accent.opacity(0.12) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if playable { playEntry(entry, in: playlist) }
        }
    }

    private func playEntry(_ entry: PlaylistEntry, in playlist: Playlist) {
        guard let payload = playlists.playableItems(from: playlist) else {
            playlists.statusMessage = settings.t("playlistNoPlayable")
            return
        }
        let index = payload.items.firstIndex { $0.id == entry.id } ?? 0
        store.player.playQueue(items: payload.items, index: index, paneLabel: playlist.name)
        store.drawerOpen = false
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button {
                if let playlist = playlists.selected { store.play(playlist) }
            } label: {
                Label(settings.t("play"), systemImage: "play.fill")
                    .font(settings.scaled(11))
            }
            .buttonStyle(.borderedProminent)
            .disabled(playlists.selected?.playableCount ?? 0 == 0)

            Button {
                if let playlist = playlists.selected { store.addSelection(to: playlist) }
            } label: {
                Label(settings.t("addSelection"), systemImage: "plus.square.on.square")
                    .font(settings.scaled(11))
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: Utilities

    private var utilitiesTab: some View {
        // The metadata editor makes this tab taller than the flyout, so the
        // whole tab scrolls as one column.
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(settings.t("sleepTimerLabel"))
                        .font(settings.scaled(13))
                    // Split over two rows. Five segments in a 320pt flyout left
                    // each label too narrow to read, and a segmented control
                    // cannot wrap itself, so the choices are laid out as a grid
                    // of buttons that look and behave like one.
                    VStack(spacing: 4) {
                        sleepTimerRow(SleepTimerOptions.allCases.prefix(3))
                        sleepTimerRow(SleepTimerOptions.allCases.dropFirst(3))
                    }
                }
                Divider().overlay(settings.palette.divider)
                TagEditorPanel(store: store, model: store.tagEditor)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    // MARK: Settings tab

    /// The gear icon and the menu's Settings… command both land here.
    private var settingsTab: some View {
        SettingsPanel()
            .environmentObject(settings)
    }

    /// One row of sleep-timer choices, spaced evenly. Buttons rather than a
    /// Picker so the row can hold an arbitrary number of options and the
    /// selection still reads at a glance.
    private func sleepTimerRow(_ options: ArraySlice<SleepTimerOptions>) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(options)) { opt in
                let selected = store.player.sleepMinutes == opt.minutes
                Button {
                    store.player.sleepMinutes = opt.minutes
                } label: {
                    Text(opt.shortLabel(settings: settings))
                        .font(settings.scaled(11))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(selected ? settings.palette.accent.opacity(0.22)
                                               : settings.palette.cardOpacityFill))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(selected ? settings.palette.accent
                                                 : settings.palette.divider,
                                        lineWidth: selected ? 1.5 : 1))
                        .foregroundStyle(selected ? settings.palette.accent : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(settings.scaled(11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
    }

    // MARK: Effects tab (#16 spectrum visualizer, #17 EQ)

    /// The visualizer runs only while this tab is on screen: the tap itself stays
    /// installed (it is just a copy into a ring buffer) but the FFT and the 30 Hz
    /// timer are switched off, so a player who never opens the drawer pays
    /// nothing for it.
    private var effectsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                crossfadeSection

                Divider().overlay(settings.palette.divider)

                SpectrumSectionView(analyzer: store.spectrum)

                Divider().overlay(settings.palette.divider)

                EqualizerSection(equalizer: store.player.equalizer)

                Divider().overlay(settings.palette.divider)

                ReplayGainSection(store: store.player.replayGain, player: store.player)

                Divider().overlay(settings.palette.divider)
                Text(settings.t("effectsSoon"))
                    .font(settings.scaled(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onAppear { store.spectrum.setActive(true) }
        .onDisappear { store.spectrum.setActive(false) }
    }

    /// Crossfade / gapless control (#14). A second engine is started just
    /// before the outgoing track ends; the choice below sets how long the two
    /// overlap. "Off" keeps the classic stop-then-start behaviour.
    private var crossfadeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(settings.t("xfTitle"))
                    .font(settings.scaled(13).weight(.medium))
                Spacer()
                Text(settings.t(store.player.crossfade.titleKey))
                    .font(settings.systemMono(10))
                    .foregroundStyle(.secondary)
            }
            Text(settings.t("xfHint"))
                .font(settings.scaled(10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                crossfadeRow(Array(CrossfadeOption.allCases))
        }
    }

    private func crossfadeRow(_ options: [CrossfadeOption]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(options)) { opt in
                let selected = store.player.crossfade == opt
                Button {
                    store.player.crossfade = opt
                } label: {
                    Text(settings.t(opt.titleKey))
                        .font(settings.scaled(11))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(selected ? settings.palette.accent.opacity(0.22)
                                               : settings.palette.cardOpacityFill))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(selected ? settings.palette.accent
                                                 : settings.palette.divider,
                                        lineWidth: selected ? 1.5 : 1))
                        .foregroundStyle(selected ? settings.palette.accent : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Spectrum visualizer along with its dB readout and decade axis (#16).
    /// Owns an @ObservedObject on the analyzer so the overlay text is swapped for
    /// bars the moment audio arrives — the parent store does not re-publish the
    /// analyzer's 30 Hz steps.
    private struct SpectrumSectionView: View {
        @ObservedObject var analyzer: SpectrumAnalyzer
        @EnvironmentObject private var settings: AppSettings

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(settings.t("spectrumTitle"))
                        .font(settings.scaled(13).weight(.medium))
                    Spacer()
                    if analyzer.hasSignal {
                        Text(levelText)
                            .font(settings.systemMono(10))
                            .foregroundStyle(.secondary)
                    }
                }

                SpectrumBars(analyzer: analyzer,
                             accent: settings.palette.accent,
                             secondary: settings.palette.folderColor)
                    .frame(height: 120)
                    .overlay {
                        if !analyzer.hasSignal && !hasAnyBars {
                            Text(settings.t("spectrumIdle"))
                                .font(settings.scaled(11))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                    }

                spectrumAxis
            }
        }

        /// Bars with any life left in them, even as they decay after the source
        /// goes quiet, mean the overlay has nothing to say.
        private var hasAnyBars: Bool {
            analyzer.bars.contains { $0 > 0.02 }
        }

        private var levelText: String {
            guard analyzer.hasSignal else { return settings.t("spectrumIdle") }
            guard let db = analyzer.peakDecibels else { return "-inf dB" }
            return String(format: "%+.1f dB", db)
        }

        /// Decade labels under the bars. Bands are log-spaced, so labelling the
        /// powers of ten lines up almost exactly with the bar positions.
        private var spectrumAxis: some View {
            GeometryReader { geo in
                let bands = analyzer.bars.count
                ZStack(alignment: .topLeading) {
                    ForEach(axisTicks, id: \.hz) { tick in
                        if tick.index != nil, bands > 0 {
                            let slot = geo.size.width / CGFloat(bands)
                            Text(axisLabel(tick.hz))
                                .font(settings.scaled(9))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .alignmentGuide(.leading) { dim in
                                    // Centre each label on its bar, but keep the first
                                    // one inside the axis instead of hanging it off
                                    // the left edge.
                                    let centre = CGFloat(tick.index!) * slot + slot / 2
                                    return tick.index == 0 ? 2 : centre - dim.width / 2
                                }
                        }
                    }
                }
                .frame(height: geo.size.height, alignment: .topLeading)
            }
            .frame(height: 12)
        }

        private struct AxisTick {
            let hz: Double
            /// Nil until the analyser has a device rate and can map bins to bands.
            let index: Int?
        }

        private var axisTicks: [AxisTick] {
            [100.0, 1_000.0, 10_000.0].map { AxisTick(hz: $0, index: bandIndex(for: $0)) }
        }

        /// First band whose centre frequency reaches `hz`.
        private func bandIndex(for hz: Double) -> Int? {
            for i in 0..<analyzer.bars.count {
                guard let f = analyzer.bandFrequency(i) else { continue }
                if f >= hz { return i }
            }
            return nil
        }

        private func axisLabel(_ hz: Double) -> String {
            hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))"
        }
    }

    /// Ten-slopers (#17). An @ObservedObject of its own so SwiftUI re-renders on
    /// Equalizer.objectWillChange (the fields live on Equalizer, not the store).
    private struct EqualizerSection: View {
        @ObservedObject var equalizer: Equalizer
        @EnvironmentObject private var settings: AppSettings

        private static let bandLabels = ["31", "62", "125", "250", "500",
                                         "1k", "2k", "4k", "8k", "16k"]

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(settings.t("eqTitle"))
                        .font(settings.scaled(13).weight(.medium))
                    Spacer()
                    Button(equalizer.isActive ? settings.t("eqOn") : settings.t("eqOff")) {
                        equalizer.toggleActive()
                    }
                    .buttonStyle(.plain)
                    .font(settings.scaled(10))
                    .foregroundStyle(settings.palette.accent)
                }
                Text(settings.t("eqHint"))
                    .font(settings.scaled(10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(settings.t("eqPresets"))
                    .font(settings.scaled(10).weight(.medium))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(EqualizerCore.presets, id: \.id) { preset in
                            let selected = equalizer.selectedPreset == preset.id
                            Button {
                                equalizer.applyPreset(id: preset.id)
                            } label: {
                                Text(settings.t("eqPreset_" + preset.id))
                                    .font(settings.scaled(10))
                                    .lineLimit(1)
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(selected ? settings.palette.accent.opacity(0.22)
                                                           : settings.palette.cardOpacityFill))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .stroke(selected ? settings.palette.accent
                                                             : settings.palette.divider,
                                                    lineWidth: selected ? 1.5 : 1))
                                    .foregroundStyle(selected ? settings.palette.accent
                                                              : Color.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .disabled(!equalizer.isActive)
                .opacity(equalizer.isActive ? 1 : 0.35)
                ForEach(0..<EqualizerCore.bandCount, id: \.self) { i in
                    let enabled = equalizer.isActive
                    HStack(spacing: 8) {
                        Text(Self.bandLabels[i])
                            .font(settings.systemMono(9))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)
                        Slider(value: equalizer.bindingFor(index: i),
                               in: EqualizerCore.minGain...EqualizerCore.maxGain)
                            .tint(settings.palette.accent)
                            .disabled(!enabled)
                            .opacity(enabled ? 1 : 0.35)
                        Text(String(format: "%+.0f", equalizer.gains[i]))
                            .font(settings.systemMono(9))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// ReplayGain section (#19). Owns an @ObservedObject on the store so the
    /// mode chips, scanning progress and per-track readouts re-render as scans
    /// finish; the player reference is only for the current-track readout and
    /// for refreshing the applied volume after a scan.
    private struct ReplayGainSection: View {
        @ObservedObject var store: ReplayGainStore
        @ObservedObject var player: PlayerState
        @EnvironmentObject private var settings: AppSettings

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(settings.t("rgTitle"))
                        .font(settings.scaled(13).weight(.medium))
                    Spacer()
                    if let entry = currentEntry() {
                        Text(String(format: "%+.1f dB", effectiveGain(entry)))
                            .font(settings.systemMono(10))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(settings.t("rgHint"))
                    .font(settings.scaled(10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                rgModeRow

                if let track = player.currentTrack {
                    if store.isScanning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(settings.t("rgScanning"))
                                .font(settings.scaled(10))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        readoutRow(for: track)
                    }
                } else {
                    Text(settings.t("rgNoTrack"))
                        .font(settings.scaled(10))
                        .foregroundStyle(.secondary)
                }

                if let status = store.status {
                    Text(status)
                        .font(settings.scaled(10))
                        .foregroundStyle(settings.palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        private var rgModeRow: some View {
            HStack(spacing: 4) {
                ForEach(ReplayGainMode.allCases, id: \.self) { mode in
                    let selected = store.mode == mode
                    Button {
                        store.mode = mode
                    } label: {
                        Text(settings.t(mode.titleKey))
                            .font(settings.scaled(11))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(selected ? settings.palette.accent.opacity(0.22)
                                                   : settings.palette.cardOpacityFill))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(selected ? settings.palette.accent
                                                     : settings.palette.divider,
                                            lineWidth: selected ? 1.5 : 1))
                            .foregroundStyle(selected ? settings.palette.accent
                                                      : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        private func readoutRow(for track: FileItem) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                if let entry = store.entry(for: track.url) {
                    Text(settings.tf("rgReadout",
                                     track.name,
                                     String(format: "%+.1f", effectiveGain(entry)),
                                     String(format: "%+.1f", entry.trackGain),
                                     entry.albumGain.map { String(format: "%+.1f", $0) } ?? "—",
                                     entry.trackLoudnessLUFS.map { String(format: "%.1f", $0) }
                                         ?? "—"))
                        .font(settings.systemMono(10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button(settings.t("rgScanFolder")) { scanFolder(track) }
                            .buttonStyle(.plain)
                            .font(settings.scaled(10))
                            .foregroundStyle(settings.palette.accent)
                        Button(settings.t("rgRemove")) { remove(track) }
                            .buttonStyle(.plain)
                            .font(settings.scaled(10))
                            .foregroundStyle(settings.palette.accent)
                    }
                } else {
                    Text(settings.t("rgNotAnalysed"))
                        .font(settings.scaled(10))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button(settings.t("rgScanTrack")) { scanTrack(track) }
                            .buttonStyle(.plain)
                            .font(settings.scaled(10))
                            .foregroundStyle(settings.palette.accent)
                        Button(settings.t("rgScanFolder")) { scanFolder(track) }
                            .buttonStyle(.plain)
                            .font(settings.scaled(10))
                            .foregroundStyle(settings.palette.accent)
                    }
                }
            }
        }

        private func currentEntry() -> ReplayGainEntry? {
            guard let track = player.currentTrack else { return nil }
            return store.entry(for: track.url)
        }

        private func effectiveGain(_ entry: ReplayGainEntry) -> Double {
            switch store.mode {
            case .off: return 0
            case .track: return entry.trackGain
            case .album: return entry.albumGain ?? 0
            }
        }

        private func scanTrack(_ track: FileItem) {
            Task {
                store.status = settings.t("rgScanning")
                let entry = await store.scan(track: track.url)
                store.status = entry != nil
                    ? settings.tf("rgDoneTrack", track.name)
                    : settings.t("rgFailed")
                player.refreshVolume()
            }
        }

        private func scanFolder(_ track: FileItem) {
            Task {
                store.status = ""
                let count = await store.scan(folder: track.url.deletingLastPathComponent())
                if count > 0 {
                    store.status = settings.tf("rgDoneFolder", count)
                } else {
                    store.status = settings.t("rgFailed")
                }
                player.refreshVolume()
            }
        }

        private func remove(_ track: FileItem) {
            store.clear(track: track.url)
            store.status = settings.t("rgRemoved")
            player.refreshVolume()
        }
    }

    private func importPlaylist() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["m3u", "m3u8"].compactMap { UTType(filenameExtension: $0) }
        panel.message = settings.t("importM3U")
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                if let imported = self.playlists.importPlaylist(from: url) {
                    self.playlists.statusMessage = self.settings.tf("playlistImported",
                                                                   imported.name,
                                                                   imported.entries.count)
                }
            }
        }
    }
}

// MARK: - Transfer overlay

struct TransferOverlay: View {
    @ObservedObject var transfer: TransferManager
    let progress: TransferManager.ProgressState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text(settings.tf("transferring", progress.current, progress.total))
                .font(settings.scaled(13).weight(.medium))
            Text(progress.name)
                .font(settings.scaled(11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(progress.mode == .copy
                 ? "\(Image(systemName: "doc.on.doc")) \(settings.t("copyToOther"))"
                 : progress.mode == .move
                 ? "\(Image(systemName: "rectangle.portrait.and.arrow.right")) \(settings.t("moveToOther"))"
                 : "\(Image(systemName: "trash")) \(settings.t("trashSel"))")
                .font(settings.scaled(10))
                .foregroundStyle(settings.palette.accent)
            Text(settings.t("renamedConflict"))
                .font(settings.scaled(9))
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        )
        .padding(40)
        .transition(.opacity)
    }
}

// MARK: - Settings sheet

/// Settings content, shared by the drawer's Settings tab. It lives in the
/// flyout rather than a modal sheet so it stays open while you pick a theme and
/// watch the rest of the app change behind it.
struct SettingsPanel: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var store = CommanderStore.shared
    @State private var showSkinImporter = false
    @State private var skinImportFailed = false

    private static let sknType: UTType =
        UTType(filenameExtension: "skn", conformingTo: .data) ?? .data

    private var versionText: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "v\(v) (build \(b))"
    }

    private func themeSwatch(_ kind: AppThemeKind) -> some View {
        let p = ThemePalette.palette(for: kind)
        let isCurrent = settings.selectedSkin == nil && settings.theme == kind
        return Button {
            settings.theme = kind
            settings.selectedSkin = nil
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(LinearGradient(colors: [p.bgTop, p.bgBottom],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                    .frame(width: 34, height: 34)
                    .overlay(
                        Circle().stroke(
                            isCurrent ? p.accent : Color.secondary.opacity(0.4),
                            lineWidth: isCurrent ? 2.5 : 1))
                Text(settings.t(kind.localizedNameKey))
                    .font(settings.scaled(10))
                    .foregroundStyle(isCurrent ? p.accent : Color.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        // Scrollable: the full settings list is taller than the flyout, and a
        // clipped control is worse than one you have to scroll to.
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(settings.t("version"))
                        .font(settings.scaled(13))
                    Spacer()
                    Text(versionText)
                        .font(settings.scaled(13).monospacedDigit().weight(.semibold))
                        .foregroundStyle(settings.palette.accent)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(settings.t("fontSize"))
                        .font(settings.scaled(13))
                    HStack {
                        Slider(value: $settings.fontScale, in: 0.85...1.30, step: 0.05)
                        Text("\(Int((settings.fontScale * 100).rounded()))%")
                            .font(settings.scaled(12).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    Text(settings.t("idleHint"))
                        .font(settings.scaled(13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(settings.t("themeLabel"))
                        .font(settings.scaled(13))
                    HStack(spacing: 14) {
                        ForEach(AppThemeKind.allCases, id: \.rawValue) { kind in
                            themeSwatch(kind)
                        }
                    }
                    if settings.theme == .custom {
                        CustomPaletteEditor()
                    }
                }

                skinsSection

                VStack(alignment: .leading, spacing: 6) {
                    Text(settings.t("languageLabel"))
                        .font(settings.scaled(13))
                    Picker("", selection: $settings.language) {
                        ForEach(Language.allCases) { lang in
                            Text(lang.nativeName).tag(lang)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle(settings.t("showAllFiles"), isOn: $settings.showAllFiles)
                        .toggleStyle(.switch)
                        .font(settings.scaled(13))
                    Text(settings.t("audioOnlyHint"))
                        .font(settings.scaled(11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Open at full available size on first launch", isOn: $settings.openAtFullSize)
                        .toggleStyle(.switch)
                        .font(settings.scaled(13))
                        .padding(.top, 4)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text(settings.t("playableFormats"))
                        .font(settings.scaled(13))
                    Text(AudioFormats.playableFormatsText)
                        .font(settings.scaled(10).monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(settings.t("notImplementedFormats"))
                        .font(settings.scaled(13))
                        .padding(.top, 4)
                    Text(AudioFormats.nonImplementedFormatsText)
                        .font(settings.scaled(10).monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fileImporter(isPresented: $showSkinImporter,
                      allowedContentTypes: [Self.sknType]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            let ok = settings.importSkin(from: url)
            if scoped { url.stopAccessingSecurityScopedResource() }
            skinImportFailed = !ok
        }
    }

    // MARK: Skins (.skn import from the Linux spec)

    @ViewBuilder
    private var skinsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(settings.t("skinsLabel"))
                    .font(settings.scaled(13))
                Spacer()
                Button {
                    showSkinImporter = true
                } label: {
                    Label(settings.t("importSkin"), systemImage: "plus.circle")
                        .labelStyle(.titleAndIcon)
                        .font(settings.scaled(11).weight(.medium))
                }
                .buttonStyle(.borderless)
            }

            if settings.skins.isEmpty {
                Text(settings.t("noSkins"))
                    .font(settings.scaled(11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(settings.skins) { skin in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(LinearGradient(colors: [skin.palette.bgTop, skin.palette.bgBottom],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 20, height: 20)
                            .overlay(
                                Circle().stroke(
                                    settings.selectedSkin == skin.name
                                        ? skin.palette.accent
                                        : Color.secondary.opacity(0.4),
                                    lineWidth: settings.selectedSkin == skin.name ? 2 : 1))
                        Text(skin.name)
                            .font(settings.scaled(12))
                        if settings.selectedSkin == skin.name {
                            Image(systemName: "checkmark")
                                .font(settings.scaled(10).weight(.bold))
                                .foregroundStyle(skin.palette.accent)
                        }
                        Spacer()
                        Button {
                            settings.removeSkin(skin.name)
                        } label: {
                            Image(systemName: "trash")
                                .font(settings.scaled(10))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help(settings.t("removeSkin"))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { settings.selectedSkin = skin.name }
                }
            }

            if skinImportFailed {
                Text(settings.t("skinBad"))
                    .font(settings.scaled(11).weight(.medium))
                    .foregroundStyle(Color.orange)
            }
        }
    }
}

// MARK: - Sleep timer options

enum SleepTimerOptions: Int, CaseIterable, Identifiable {
    case off = 0, m15 = 15, m30 = 30, m60 = 60, m90 = 90
    var id: Int { rawValue }
    var minutes: Int { rawValue }

    @MainActor
    func label(settings: AppSettings) -> String {
        switch self {
        case .off: return settings.t("sleepOff")
        case .m15: return settings.tf("sleepMinutes", 15)
        case .m30: return settings.tf("sleepMinutes", 30)
        case .m60: return settings.tf("sleepMinutes", 60)
        case .m90: return settings.tf("sleepMinutes", 90)
        }
    }

    /// Compact form for the flyout's two-row grid, where "60 minutes" does not
    /// fit a third of a 320pt drawer.
    @MainActor
    func shortLabel(settings: AppSettings) -> String {
        switch self {
        case .off: return settings.t("sleepOff")
        case .m15: return settings.tf("sleepMinutesShort", 15)
        case .m30: return settings.tf("sleepMinutesShort", 30)
        case .m60: return settings.tf("sleepMinutesShort", 60)
        case .m90: return settings.tf("sleepMinutesShort", 90)
        }
    }
}

// MARK: - Playback bar

struct PlaybackBar: View {
    @ObservedObject var player: PlayerState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 10) {
            if let track = player.currentTrack {
                Image(systemName: "music.note")
                    .foregroundStyle(settings.palette.accent)

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.name)
                        .font(settings.scaled(13).weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        if let pane = player.sourcePane {
                            Text(settings.tf("fromPane", pane))
                                .font(settings.scaled(10))
                                .foregroundStyle(.secondary)
                        }
                        if let note = player.playbackNote {
                            Text(note)
                                .font(settings.scaled(10))
                                .foregroundStyle(Color.orange)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: 300, alignment: .leading)

                transportButtons

                Text(AudioFormats.durationText(player.currentTime))
                    .font(settings.scaled(11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { min(player.currentTime, max(player.duration, 0.001)) },
                    set: { player.seek(to: $0) }),
                       in: 0...max(player.duration, 0.001))
                    .frame(maxWidth: .infinity)
                    .help(settings.t("seekHelp"))
                Text(AudioFormats.durationText(player.duration))
                    .font(settings.scaled(11).monospacedDigit())
                    .foregroundStyle(.secondary)

                Image(systemName: "speaker.wave.2.fill")
                    .font(settings.scaled(11))
                    .foregroundStyle(.secondary)
                    .help(settings.t("volumeHelp"))
                Slider(value: $player.volume, in: 0...1)
                    .frame(width: 88)
                    .help(settings.t("volumeHelp"))
            } else {
                Image(systemName: "music.quarternote.3")
                    .foregroundStyle(.secondary)
                Text(settings.t("idleHint"))
                    .font(settings.scaled(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(settings.palette.cardOpacityFill)
    }

    private var transportButtons: some View {
        HStack(spacing: 6) {
            Button {
                player.shuffleMode.toggle()
            } label: {
                Image(systemName: "shuffle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(player.shuffleMode ? settings.palette.accent : .secondary)
            .help(player.shuffleMode ? settings.t("shuffleOn") : settings.t("shuffleOff"))

            Button {
                player.repeatMode = player.repeatMode.next
            } label: {
                Image(systemName: player.repeatMode.systemImage)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(player.repeatMode == .off ? Color.secondary : settings.palette.accent)
            .help(settings.t(repeatHelpKey))

            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.borderless)
            .help(settings.t("prevHelp"))

            Button {
                player.togglePause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderedProminent)
            .tint(settings.palette.accent)
            .help(player.isPlaying ? settings.t("pauseHelp") : settings.t("resumeHelp"))

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.borderless)
            .help(settings.t("nextHelp"))
        }
    }

    private var repeatHelpKey: String {
        switch player.repeatMode {
        case .off: return "repeatOff"
        case .all: return "repeatAll"
        case .one: return "repeatOne"
        }
    }
}

struct ColorPickerRow: View {
    let labelKey: String
    @Binding var color: Color
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        HStack {
            Text(settings.t(labelKey))
                .font(settings.scaled(11))
                .frame(width: 90, alignment: .leading)
            ColorPicker("", selection: $color, supportsOpacity: true)
                .labelsHidden()
            Spacer()
        }
    }
}

struct CustomPaletteEditor: View {
    @EnvironmentObject var settings: AppSettings
    @State private var custom = CustomPalette.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(settings.palette.divider)
            Text(settings.t("customPalette"))
                .font(settings.scaled(12).weight(.medium))
            ColorPickerRow(labelKey: "customBgTop", color: $custom.bgTop)
            ColorPickerRow(labelKey: "customBgBottom", color: $custom.bgBottom)
            ColorPickerRow(labelKey: "customCard", color: $custom.cardOpacityFill)
            ColorPickerRow(labelKey: "customDivider", color: $custom.divider)
            ColorPickerRow(labelKey: "customAccent", color: $custom.accent)
            ColorPickerRow(labelKey: "customFolder", color: $custom.folderColor)
            Toggle(settings.t("customIsDark"), isOn: $custom.isDark)
                .font(settings.scaled(11))
            HStack {
                Button(settings.t("customApply")) {
                    custom.save()
                    settings.selectedSkin = nil
                    settings.theme = .custom
                    AppSettings.shared.objectWillChange.send()
                }
                .buttonStyle(.bordered)
                .font(settings.scaled(11))
                Button(settings.t("customReset")) {
                    custom = CustomPalette.defaults()
                }
                .buttonStyle(.borderless)
                .font(settings.scaled(11))
            }
        }
    }
}
