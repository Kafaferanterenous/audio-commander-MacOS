import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Function-key equivalents (F1-F12 live in Unicode's private-use area).
extension KeyEquivalent {
    init(functionKey code: Int) {
        self = KeyEquivalent(Character(UnicodeScalar(UInt32(code))!))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
    let player = PlayerState()
    let transfer = TransferManager()

    var activePane: PaneState { activeSide == "right" ? right : left }

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
        }
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
            source.statusMessage = transfer.lastResultMessage
            source.selectedIDs.removeAll()
            await source.refresh()
            await destination.refresh()
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
            source.statusMessage = transfer.lastResultMessage
            source.selectedIDs.removeAll()
            await source.refresh()
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
    @FocusState private var focusedPane: PaneSide?
    @State private var showSettings = false

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
        .overlay {
            if let progress = store.transfer.progress {
                TransferOverlay(transfer: store.transfer, progress: progress)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
        }
        .onChange(of: settings.settingsRequest) { _ in
            showSettings = true
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

    private var topButtons: some View {
        ZStack {
            HStack {
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13).weight(.medium))
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
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

struct SettingsSheet: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
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
        VStack(alignment: .leading, spacing: 16) {
            Text(settings.t("settings"))
                .font(settings.scaled(17).weight(.bold))

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

            HStack {
                Spacer()
                Button(settings.t("close")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .background(
            LinearGradient(colors: [settings.palette.bgTop, settings.palette.bgBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .preferredColorScheme(settings.palette.colorScheme)
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
}
