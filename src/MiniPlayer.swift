import SwiftUI
import AppKit

/// Goal #13 — MINI PLAYER.
///
/// A separate floating window that lives OUTSIDE the Inspector drawer, so the
/// drawer keeps only its three tabs (Library / Effects / Utilities).
///
/// Design decisions:
///  * `NSPanel` at `.floating` level with `becomesKeyOnlyIfNeeded`, so it floats
///    above the main window WITHOUT taking key focus — the panes keep working
///    (type-ahead, shortcuts) while it sits on top.
///  * `.titled + .closable + .utilityWindow` so the system title bar still gives
///    drag-by-title-bar and the close button for free.
///  * Non-activating: showing it never pulls the app to the front.
///  * Frame and open-state persist in UserDefaults; it is restored at launch.
///  * Closing the MAIN window while the mini player is up keeps the app (and
///    playback) alive — see `AppDelegate.applicationShouldTerminateAfterLast-
///    WindowClosed`; the mini player then offers a way back to the main window.
@MainActor
final class MiniPlayerController: ObservableObject {
    static let shared = MiniPlayerController()

    @Published private(set) var isOpen = false

    nonisolated static let panelID =
        NSUserInterfaceItemIdentifier("com.opencode.audiocommander.miniplayer")
    private static let frameKey = "ac_mini_frame"
    private static let openKey = "ac_mini_open"
    private static let defaultSize = NSSize(width: 380, height: 128)

    private var panel: NSPanel?
    private var frameSaveTask: Task<Void, Never>?

    private init() {}

    // MARK: - Open / close

    func toggle() { isOpen ? close() : show() }

    func show() {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        restoreFrame(into: panel)
        panel.orderFront(nil)
        isOpen = true
        UserDefaults.standard.set(true, forKey: Self.openKey)
    }

    func close() {
        saveFrame()
        panel?.orderOut(nil)
        isOpen = false
        UserDefaults.standard.set(false, forKey: Self.openKey)
    }

    /// Called at launch: reopens the panel if the user left it open.
    func restoreIfOpen() {
        guard UserDefaults.standard.bool(forKey: Self.openKey) else { return }
        show()
    }

    /// The panel is closed by its title-bar close button.
    func panelClosedExternally() {
        saveFrame()
        isOpen = false
        UserDefaults.standard.set(false, forKey: Self.openKey)
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered,
                            defer: false)
        panel.identifier = Self.panelID
        panel.title = "AudioCommander"
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 320, height: 116)
        panel.contentView = NSHostingView(
            rootView: MiniPlayerView()
                .environmentObject(AppSettings.shared)
                .environmentObject(CommanderStore.shared.player))
        panel.delegate = MiniPanelDelegate.shared
        return panel
    }

    // MARK: - Frame persistence

    func scheduleFrameSave() {
        frameSaveTask?.cancel()
        frameSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveFrame()
        }
    }

    private func saveFrame() {
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
    }

    private func restoreFrame(into panel: NSPanel) {
        let stored = UserDefaults.standard.string(forKey: Self.frameKey).map(NSRectFromString)
        guard let r = stored, r.width >= 300, r.height >= 110 else {
            centerOnScreen(panel)
            return
        }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max(r.minX, visible.minX), max(visible.maxX - r.width, visible.minX))
        let y = min(max(r.minY, visible.minY), max(visible.maxY - r.height, visible.minY))
        panel.setFrame(NSRect(x: x, y: y, width: r.width, height: r.height), display: false)
    }

    /// First launch: top-right of the main window, else top-right of the screen.
    private func centerOnScreen(_ panel: NSPanel) {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = AppDelegate.current?.frame ?? visible
        var x = anchor.maxX - panel.frame.width - 24
        var y = anchor.maxY - panel.frame.height - 24
        x = min(max(x, visible.minX), max(visible.maxX - panel.frame.width, visible.minX))
        y = min(max(y, visible.minY), max(visible.maxY - panel.frame.height, visible.minY))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Window delegate for the mini player. The callbacks arrive on the main
/// thread but outside the actor, hence `MainActor.assumeIsolated` (same
/// pattern as `AppDelegate`).
final class MiniPanelDelegate: NSObject, NSWindowDelegate {
    static let shared = MiniPanelDelegate()

    func windowWillClose(_ notification: Notification) {
        guard isMini(notification) else { return }
        MainActor.assumeIsolated { MiniPlayerController.shared.panelClosedExternally() }
    }

    func windowDidMove(_ notification: Notification) {
        guard isMini(notification) else { return }
        MainActor.assumeIsolated { MiniPlayerController.shared.scheduleFrameSave() }
    }

    func windowDidResize(_ notification: Notification) {
        guard isMini(notification) else { return }
        MainActor.assumeIsolated { MiniPlayerController.shared.scheduleFrameSave() }
    }

    private func isMini(_ notification: Notification) -> Bool {
        (notification.object as? NSWindow)?.identifier == MiniPlayerController.panelID
    }
}

// MARK: - Mini player content

struct MiniPlayerView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: PlayerState

    private let corner: CGFloat = 10

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            seekRow
            hairline
            transportRow
        }
        .background(
            LinearGradient(colors: [settings.palette.bgTop, settings.palette.bgBottom],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .preferredColorScheme(settings.palette.colorScheme)
    }

    private var hairline: some View {
        Rectangle().fill(settings.palette.divider).frame(height: 1)
    }

    // MARK: Header: note icon, track name, back-to-main-window button

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: player.currentTrack == nil ? "music.quarternote.3" : "music.note")
                .font(.system(size: 12))
                .foregroundStyle(player.currentTrack == nil
                                 ? Color.secondary : settings.palette.accent)

            if let track = player.currentTrack {
                Text(track.name)
                    .font(settings.scaled(12).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(track.url.path)
            } else {
                Text(settings.t("miniIdle"))
                    .font(settings.scaled(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Button {
                AppDelegate.revealMainWindow()
            } label: {
                Image(systemName: "macwindow")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(settings.t("miniShowMain"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: Seek row

    private var seekRow: some View {
        HStack(spacing: 8) {
            Text(AudioFormats.durationText(player.currentTime))
                .font(settings.scaled(10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
            Slider(value: Binding(
                get: { min(player.currentTime, max(player.duration, 0.001)) },
                set: { player.seek(to: $0) }),
                   in: 0...max(player.duration, 0.001))
                .disabled(player.currentTrack == nil)
                .help(settings.t("seekHelp"))
            Text(AudioFormats.durationText(player.duration))
                .font(settings.scaled(10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: Transport row

    private var transportRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                transportButton("backward.fill", help: settings.t("prevHelp")) { player.previous() }
                    .disabled(!player.hasPrevious)

                Button { player.togglePause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(settings.palette.accent)
                .disabled(player.currentTrack == nil)
                .help(player.isPlaying ? settings.t("pauseHelp") : settings.t("resumeHelp"))

                transportButton("forward.fill", help: settings.t("nextHelp")) { player.next() }
                    .disabled(!player.hasNext)
            }

            Spacer(minLength: 0)

            if let note = player.playbackNote {
                Text(note)
                    .font(settings.scaled(9))
                    .foregroundStyle(Color.orange)
                    .lineLimit(1)
                    .help(note)
            } else if let pane = player.sourcePane {
                Text(settings.tf("fromPane", pane))
                    .font(settings.scaled(9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Image(systemName: "speaker.wave.2.fill")
                .font(settings.scaled(10))
                .foregroundStyle(.secondary)
                .help(settings.t("volumeHelp"))
            Slider(value: $player.volume, in: 0...1)
                .frame(width: 78)
                .help(settings.t("volumeHelp"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func transportButton(_ symbol: String, help: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
