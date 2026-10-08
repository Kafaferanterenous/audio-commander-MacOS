import Foundation
import SwiftUI

enum Language: String, CaseIterable, Identifiable {
    case english, polish, italian, chinese
    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .english: return "English"
        case .polish: return "Polski"
        case .italian: return "Italiano"
        case .chinese: return "中文（简体）"
        }
    }
}

enum AppThemeKind: String, CaseIterable, Identifiable {
    case dark, light, pastel, steelBlue, custom
    var id: String { rawValue }

    var localizedNameKey: String {
        switch self {
        case .dark: return "themeDark"
        case .light: return "themeLight"
        case .pastel: return "themePastel"
        case .steelBlue: return "themeSteelBlue"
        case .custom: return "themeCustom"
        }
    }
}

struct ThemePalette {
    let bgTop: Color
    let bgBottom: Color
    let cardOpacityFill: Color
    let divider: Color
    let accent: Color
    let folderColor: Color
    let colorScheme: ColorScheme

    static func palette(for kind: AppThemeKind) -> ThemePalette {
        switch kind {
        case .dark:
            return ThemePalette(
                bgTop: Color(red: 0.085, green: 0.075, blue: 0.13),
                bgBottom: Color(red: 0.12, green: 0.11, blue: 0.19),
                cardOpacityFill: Color.white.opacity(0.04),
                divider: Color.white.opacity(0.10),
                accent: Color(red: 0.78, green: 0.66, blue: 0.98),
                folderColor: Color(red: 0.55, green: 0.62, blue: 0.95),
                colorScheme: .dark)
        case .light:
            return ThemePalette(
                bgTop: Color(red: 0.96, green: 0.96, blue: 0.98),
                bgBottom: Color(red: 0.89, green: 0.90, blue: 0.94),
                cardOpacityFill: Color.black.opacity(0.03),
                divider: Color.black.opacity(0.14),
                accent: Color(red: 0.42, green: 0.31, blue: 0.73),
                folderColor: Color(red: 0.35, green: 0.47, blue: 0.90),
                colorScheme: .light)
        case .pastel:
            return ThemePalette(
                bgTop: Color(red: 0.995, green: 0.945, blue: 0.92),
                bgBottom: Color(red: 0.975, green: 0.925, blue: 0.885),
                cardOpacityFill: Color.white.opacity(0.55),
                divider: Color(red: 0.78, green: 0.62, blue: 0.52),
                accent: Color(red: 0.72, green: 0.52, blue: 0.42),
                folderColor: Color(red: 0.58, green: 0.66, blue: 0.92),
                colorScheme: .light)
        case .steelBlue:
            return ThemePalette(
                bgTop: Color(red: 0.06, green: 0.14, blue: 0.22),
                bgBottom: Color(red: 0.09, green: 0.19, blue: 0.31),
                cardOpacityFill: Color.white.opacity(0.07),
                divider: Color.white.opacity(0.16),
                accent: Color(red: 0.48, green: 0.72, blue: 0.95),
                folderColor: Color(red: 0.56, green: 0.80, blue: 0.98),
                colorScheme: .dark)
        case .custom:
            let c = CustomPalette.load()
            return c.toThemePalette()
        }
    }
}


struct CustomPalette {
    var bgTop: Color
    var bgBottom: Color
    var cardOpacityFill: Color
    var divider: Color
    var accent: Color
    var folderColor: Color
    var isDark: Bool

    static func defaults() -> CustomPalette {
        return CustomPalette(
            bgTop: Color(red: 0.085, green: 0.075, blue: 0.13),
            bgBottom: Color(red: 0.12, green: 0.11, blue: 0.19),
            cardOpacityFill: Color.white.opacity(0.04),
            divider: Color.white.opacity(0.10),
            accent: Color(red: 0.78, green: 0.66, blue: 0.98),
            folderColor: Color(red: 0.55, green: 0.62, blue: 0.95),
            isDark: true)
    }

    func toThemePalette() -> ThemePalette {
        return ThemePalette(
            bgTop: bgTop,
            bgBottom: bgBottom,
            cardOpacityFill: cardOpacityFill,
            divider: divider,
            accent: accent,
            folderColor: folderColor,
            colorScheme: isDark ? .dark : .light)
    }

    static func load() -> CustomPalette {
        let d = UserDefaults.standard
        func c(_ k: String) -> Color? {
            guard let data = d.data(forKey: k),
                  let cod = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else { return nil }
            return Color(cod)
        }
        if let bgTop = c("ac_c_bgTop"),
           let bgBottom = c("ac_c_bgBottom"),
           let card = c("ac_c_card"),
           let divider = c("ac_c_div"),
           let accent = c("ac_c_accent"),
           let folder = c("ac_c_folder") {
            return CustomPalette(bgTop: bgTop, bgBottom: bgBottom, cardOpacityFill: card, divider: divider, accent: accent, folderColor: folder, isDark: d.bool(forKey: "ac_c_isDark"))
        }
        return defaults()
    }

    func save() {
        let d = UserDefaults.standard
        func s(_ k: String, _ col: Color) {
            if let ns = NSColor(col).usingColorSpace(.sRGB) {
                if let data = try? NSKeyedArchiver.archivedData(withRootObject: ns, requiringSecureCoding: false) {
                    d.set(data, forKey: k)
                }
            }
        }
        s("ac_c_bgTop", bgTop)
        s("ac_c_bgBottom", bgBottom)
        s("ac_c_card", cardOpacityFill)
        s("ac_c_div", divider)
        s("ac_c_accent", accent)
        s("ac_c_folder", folderColor)
        d.set(isDark, forKey: "ac_c_isDark")
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var language: Language {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "ac_language") }
    }
    @Published var theme: AppThemeKind {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "ac_theme") }
    }
    @Published var fontScale: Double {
        didSet { UserDefaults.standard.set(fontScale, forKey: "ac_font_scale") }
    }
    @Published private(set) var skins: [SknEntry] = []
    @Published var selectedSkin: String? {
        didSet { UserDefaults.standard.set(selectedSkin, forKey: "ac_skn") }
    }
    @Published var settingsRequest = 0

    @Published var showAllFiles: Bool {
        didSet { UserDefaults.standard.set(showAllFiles, forKey: "ac_show_all") }
    }
    @Published var openAtFullSize: Bool {
        didSet { UserDefaults.standard.set(openAtFullSize, forKey: "ac_open_full") }
    }

    func requestSettings() { settingsRequest += 1 }

    // Imported .skn palettes override the built-in theme while selected.
    var palette: ThemePalette {
        if let name = selectedSkin,
           let entry = skins.first(where: { $0.name == name }) {
            return entry.palette
        }
        return ThemePalette.palette(for: theme)
    }

    // MARK: Skins (.skn import, Linux-spec)

    private var skinsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AudioCommander/Skins", isDirectory: true)
    }

    func loadSkinsFromDisk() {
        let dir = skinsDir
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]))?.filter { $0.pathExtension.lowercased() == "skn" } ?? []
        var loaded: [SknEntry] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if let colors = SknParser.load(from: file) {
                loaded.append(SknEntry(name: file.deletingPathExtension().lastPathComponent,
                                       palette: SknParser.palette(for: colors)))
            }
        }
        skins = loaded
        if let selected = selectedSkin, !loaded.contains(where: { $0.name == selected }) {
            selectedSkin = nil
        }
    }

    @discardableResult
    func importSkin(from url: URL) -> Bool {
        guard let colors = SknParser.load(from: url) else { return false }
        let dir = skinsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(url.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            return false
        }
        loadSkinsFromDisk()
        selectedSkin = target.deletingPathExtension().lastPathComponent
        _ = colors
        return true
    }

    func removeSkin(_ name: String) {
        let target = skinsDir.appendingPathComponent(name + ".skn")
        try? FileManager.default.removeItem(at: target)
        loadSkinsFromDisk()
    }

    init() {
        let defaults = UserDefaults.standard
        language = defaults.string(forKey: "ac_language")
            .flatMap(Language.init(rawValue:)) ?? .english
        theme = defaults.string(forKey: "ac_theme")
            .flatMap(AppThemeKind.init(rawValue:)) ?? .dark
        let stored = defaults.double(forKey: "ac_font_scale")
        fontScale = stored > 0 ? stored : 1.0
        selectedSkin = defaults.string(forKey: "ac_skn")
        showAllFiles = defaults.bool(forKey: "ac_show_all")
        openAtFullSize = defaults.object(forKey: "ac_open_full") == nil ? true : defaults.bool(forKey: "ac_open_full")
        loadSkinsFromDisk()
    }

    func scaled(_ size: CGFloat) -> Font {
        .system(size: size * fontScale)
    }

    /// Monospaced, for readouts whose digits must not jitter as they change
    /// (the spectrum level readout, #16).
    func systemMono(_ size: CGFloat) -> Font {
        .system(size: size * fontScale, design: .monospaced)
    }

    func t(_ key: String) -> String {
        Self.string(key, for: language)
    }

    func tf(_ key: String, _ args: CVarArg...) -> String {
        String(format: Self.string(key, for: language), arguments: args)
    }

    private static func string(_ key: String, for lang: Language) -> String {
        if let s = tables[lang]?[key] { return s }
        return tables[.english]?[key] ?? key
    }

    private static let tables: [Language: [String: String]] = [
        .english: [
            "left": "Left", "right": "Right",
            "up": "Up one folder", "refresh": "Refresh",
            "chooseFolder": "Choose folder…", "recentFolders": "Recent folders",
            "name": "Name", "size": "Size", "duration": "Duration",
            "foldersN": "folder(s)", "filesN": "file(s)", "audioN": "audio",
            "playedLength": "played length %1$@ of %2$@",
            "select": "Select", "deselect": "Deselect",
            "sortHelp": "Sort by %@",
            "seekHelp": "Seek position", "volumeHelp": "Volume",
            "playAll": "Play all",
            "playAllHelp": "Play every audio file in this folder, in sorted order",
            "notAnAudio": "Not an audio file: %@",
            "cantDecode": "Can't decode \"%@\" — skipping",
            "noPlayable": "No playable tracks in this folder",
            "idleHint": "Click an audio file to play — click again to stop",
            "fromPane": "from %@ pane",
            "prevHelp": "Previous (restarts current track after 3s)",
            "nextHelp": "Next",
            "pauseHelp": "Pause", "resumeHelp": "Play",
            "shuffleOn": "Shuffle on", "shuffleOff": "Shuffle off",
            "repeatOff": "Repeat off", "repeatAll": "Repeat all",
            "repeatOne": "Repeat one",
            "drawerTitle": "", "drawerLibrary": "Library",
            "drawerEffects": "Effects", "drawerUtilities": "Utilities",
            "newPlaylist": "New", "importM3U": "Import…",
            "playlistName": "Playlist name", "noPlaylists":
                "No playlists yet. Create one, or import an .m3u file from anywhere.",
            "selectPlaylistPrompt": "Pick a playlist to see its tracks.",
            "playlistEmpty": "This playlist has no tracks yet.",
            "playlistImported": "Imported “%@” (%d tracks)",
            "playlistAdded": "Added %d track(s) to “%@”",
            "playlistNoPlayable": "No playable tracks in this playlist",
            "playlistBad": "Could not read “%@”",
            "addSelection": "Add selection", "removeEntry": "Remove from playlist",
            "deletePlaylist": "Delete playlist",
            "deletePlaylistConfirm": "Delete the playlist “%@”? The .m3u file is removed.",
            "renamePlaylist": "Rename…", "missingFile": "missing",
            "unsupportedFile": "unsupported", "missingN": "%d missing",
            "playFromHere": "Play from here",
            "spectrumTitle": "Spectrum",
            "spectrumIdle":
                "Play something to see the spectrum. This source does not feed the analyser.",
            "effectsSoon":
                "More effects are planned for this tab.",
            "xfTitle": "Crossfade",
            "xfHint": "Overlaps the end of one track with the start of the next. Gapless uses a very short overlap. Native formats only.",
            "xfOff": "Off", "xfGapless": "Gapless",
            "xfThree": "3 s",
            "eqTitle": "Equalizer",
            "eqHint": "Ten bands inserted into the in-app engines (native, embedded, MIDI). The AVPlayer fallback path stays flat.",
            "eqOn": "On", "eqOff": "Off", "eqReset": "Reset",
            "eqPresets": "Presets",
            "eqPreset_flat": "Flat", "eqPreset_pop": "Pop", "eqPreset_rock": "Rock",
            "eqPreset_classical": "Classical", "eqPreset_jazz": "Jazz",
            "eqPreset_electronic": "Electronic", "eqPreset_hiphop": "Hip-Hop",
            "eqPreset_bassboost": "Bass Boost", "eqPreset_vocalboost": "Vocal Boost",
            "eqPreset_trebleboost": "Treble Boost",
            "rgTitle": "ReplayGain",
            "rgHint": "Normalizes tracks to the same loudness (EBU R128, target 89 dB). Measurements are stored in a small .replaygain file next to each track — your files are never rewritten.",
            "rgOff": "Off", "rgTrack": "Track", "rgAlbum": "Album",
            "rgNoTrack": "Play or select a track to analyse it.",
            "rgNotAnalysed": "Not analysed yet.",
            "rgScanTrack": "Analyse this track",
            "rgScanFolder": "Analyse folder (album)",
            "rgRemove": "Remove measurement",
            "rgScanning": "Analysing…",
            "rgDoneTrack": "Analysed “%@”",
            "rgDoneFolder": "Analysed %d file(s)",
            "rgFailed": "Could not analyse — unsupported or unreadable.",
            "rgRemoved": "Measurement removed.",
            "rgReadout": "%1$@: gain %2$@ dB · track %3$@ dB · album %4$@ dB · loudness %5$@ LUFS",
            "copyToOther": "Copy selection to the other pane",
            "moveToOther": "Move selection to the other pane",
            "selectFirst": "Select items with the circle checkboxes first",
            "copiedDone": "Copied %d item(s)",
            "movedDone": "Moved %d item(s)",
            "opErrors": ", %d error(s)",
            "transferring": "Transferring %d of %d…",
            "dropNothing": "Nothing to copy from this drop",
            "renamedConflict": "renamed on conflict",
            "settings": "Settings", "version": "Version",
            "fontSize": "Font size", "languageLabel": "Language", "themeLabel": "Theme",
            "themeDark": "Dark", "themeLight": "Light",
            "themePastel": "Pastel",             "themeSteelBlue": "Steel Blue", "themeCustom": "Custom",
            "customPalette": "Custom palette", "customBgTop": "Background top", "customBgBottom": "Background bottom",
            "customCard": "Card", "customDivider": "Divider", "customAccent": "Accent", "customFolder": "Folder",
            "customIsDark": "Dark scheme", "customApply": "Apply", "customReset": "Reset",
            "close": "Close",
            "openCtx": "Open", "finderCtx": "Show in Finder",
            "stopTip": "Playing — click to stop",
            "swapPanes": "Swap panes",
            "trashSel": "Move selection to Trash",
            "trashedDone": "Trashed %d item(s)",
            "skinsLabel": "Skins", "importSkin": "Import .skn…",
            "skinBad": "Invalid .skn file",
            "noSkins": "No skins imported yet",
            "removeSkin": "Remove this skin",
            "showAllFiles": "Show all files",
            "audioOnlyHint": "When off, the panes list only folders and audio files this app can play.",
            "playableFormats": "Audio formats this app can play",
            "notImplementedFormats": "Audio formats recognized but not implemented yet",
            "sleepTimerLabel": "Sleep timer",
            "sleepOff": "Off",
            "sleepMinutes": "%d minutes",
            "sleepMinutesShort": "%d min",
            "miniPlayer": "Mini player",
            "miniIdle": "Nothing playing",
            "miniShowMain": "Show the main window",
            "metadataTitle": "Metadata (ID3)",
            "tagTitleLabel": "Title", "tagArtistLabel": "Artist",
            "tagAlbumLabel": "Album", "tagTrackLabel": "Track",
            "tagYearLabel": "Year", "tagGenreLabel": "Genre",
            "tagCommentLabel": "Comment",
            "tagSave": "Save tags", "tagReload": "Reload",
            "tagsSaved": "Tags saved", "tagsSaveFailed": "Could not save tags",
            "tagsUnsaved": "Unsaved changes",
            "tagsFormatNote": "ID3v2 tag — written into the file",
            "tagsMp3Only": "Tag editing is available for MP3 (ID3) files. Other formats use their own tag systems.",
            "tagsNoSelection": "Select one audio file, or play a track, to see its tags."
        ],
        .polish: [
            "left": "Lewy", "right": "Prawy",
            "up": "Poziom wyżej", "refresh": "Odśwież",
            "chooseFolder": "Wybierz folder…", "recentFolders": "Ostatnie foldery",
            "name": "Nazwa", "size": "Rozmiar", "duration": "Czas",
            "foldersN": "folder(y)", "filesN": "plik(i)", "audioN": "audio",
            "playedLength": "łączny czas %1$@ z %2$@",
            "select": "Zaznacz", "deselect": "Odznacz",
            "sortHelp": "Sortuj według: %@",
            "seekHelp": "Pozycja odtwarzania", "volumeHelp": "Głośność",
            "playAll": "Odtwórz wszystko",
            "playAllHelp": "Odtwórz wszystkie pliki audio z tego folderu według sortowania",
            "notAnAudio": "To nie jest plik audio: %@",
            "cantDecode": "Nie można zdekodować \"%@\" — pomijam",
            "noPlayable": "Brak odtwarzalnych plików w tym folderze",
            "idleHint": "Kliknij plik audio, aby odtworzyć — kliknij ponownie, aby zatrzymać",
            "fromPane": "z panelu %@",
            "prevHelp": "Poprzedni (ponowne uruchomienie utworu po 3 s)",
            "nextHelp": "Następny",
            "pauseHelp": "Pauza", "resumeHelp": "Odtwórz",
            "shuffleOn": "Losowanie włączone", "shuffleOff": "Losowanie wyłączone",
            "repeatOff": "Powtarzanie wyłączone", "repeatAll": "Powtarzaj wszystko",
            "repeatOne": "Powtarzaj utwór",
            "drawerTitle": "", "drawerLibrary": "Biblioteka",
            "drawerEffects": "Efekty", "drawerUtilities": "Narzędzia",
            "newPlaylist": "Nowa", "importM3U": "Importuj…",
            "playlistName": "Nazwa playlisty", "noPlaylists":
                "Brak playlist. Utwórz nową lub zaimportuj plik .m3u.",
            "selectPlaylistPrompt": "Wybierz playlistę, aby zobaczyć utwory.",
            "playlistEmpty": "Ta playlista jest jeszcze pusta.",
            "playlistImported": "Zaimportowano „%@” (%d utworów)",
            "playlistAdded": "Dodano %d utwor(ów) do „%@”",
            "playlistNoPlayable": "Brak odtwarzalnych utworów na tej playliście",
            "playlistBad": "Nie można odczytać „%@”",
            "addSelection": "Dodaj zaznaczenie", "removeEntry": "Usuń z playlisty",
            "deletePlaylist": "Usuń playlistę",
            "deletePlaylistConfirm": "Usunąć playlistę „%@”? Plik .m3u zostanie skasowany.",
            "renamePlaylist": "Zmień nazwę…", "missingFile": "brak pliku",
            "unsupportedFile": "nieobsługiwany", "missingN": "%d brakujących",
            "playFromHere": "Odtwórz od tego miejsca",
            "spectrumTitle": "Widmo",
            "spectrumIdle":
                "Odtwórz coś, aby zobaczyć widmo. To źródło nie zasila analizatora.",
            "effectsSoon":
                "Więcej efektów pojawi się w tej zakładce.",
            "xfTitle": "Przenikanie",
            "xfHint": "Nakłada koniec utworu na początek następnego. Bez przerw używa bardzo krótkiego nakładania. Tylko formaty natywne.",
            "xfOff": "Wył.", "xfGapless": "Bez przerw",
            "xfThree": "3 s",
            "eqTitle": "Korektor",
            "eqHint": "Dziesięć pasm w silnikach aplikacji (natywne, wbudowane, MIDI). Ścieżka rezerwowa AVPlayer pozostaje płaska.",
            "eqOn": "On", "eqOff": "Off", "eqReset": "Zerowanie",
            "eqPresets": "Presety",
            "eqPreset_flat": "Płasko", "eqPreset_pop": "Pop", "eqPreset_rock": "Rock",
            "eqPreset_classical": "Klasyka", "eqPreset_jazz": "Jazz",
            "eqPreset_electronic": "Elektronika", "eqPreset_hiphop": "Hip-Hop",
            "eqPreset_bassboost": "Bass Boost", "eqPreset_vocalboost": "Wzmocnij wokale",
            "eqPreset_trebleboost": "Treble Boost",
            "rgTitle": "ReplayGain",
            "rgHint": "Wyrównuje głośność utworów (EBU R128, poziom docelowy 89 dB). Wyniki zapisywane są w małym pliku .replaygain obok każdego utworu — pliki źródłowe nie są zmieniane.",
            "rgOff": "Wył.", "rgTrack": "Utwór", "rgAlbum": "Album",
            "rgNoTrack": "Odtwórz lub zaznacz utwór, aby go przeanalizować.",
            "rgNotAnalysed": "Jeszcze nie przeanalizowano.",
            "rgScanTrack": "Analizuj utwór",
            "rgScanFolder": "Analizuj folder (album)",
            "rgRemove": "Usuń pomiar",
            "rgScanning": "Analizowanie…",
            "rgDoneTrack": "Przeanalizowano „%@”",
            "rgDoneFolder": "Przeanalizowano %d plik(ów)",
            "rgFailed": "Nie można przeanalizować — format nieobsługiwany lub plik nieczytelny.",
            "rgRemoved": "Usunięto pomiar.",
            "rgReadout": "%1$@: wzmocnienie %2$@ dB · utwór %3$@ dB · album %4$@ dB · głośność %5$@ LUFS",
            "copyToOther": "Kopiuj zaznaczone do drugiego panelu",
            "moveToOther": "Przenieś zaznaczone do drugiego panelu",
            "selectFirst": "Najpierw zaznacz pliki kółkami wyboru",
            "copiedDone": "Skopiowano: %d",
            "movedDone": "Przeniesiono: %d",
            "opErrors": ", błędy: %d",
            "transferring": "Przesyłanie %d z %d…",
            "dropNothing": "Brak plików do skopiowania z przeciągnięcia",
            "renamedConflict": "zmieniono nazwę przy konflikcie",
            "settings": "Ustawienia", "version": "Wersja",
            "fontSize": "Rozmiar czcionki", "languageLabel": "Język", "themeLabel": "Motyw",
            "themeDark": "Ciemny", "themeLight": "Jasny",
            "themePastel": "Pastelowy",             "themeSteelBlue": "Stalowy niebieski", "themeCustom": "Własny",
            "customPalette": "Paleta własna", "customBgTop": "Tło góra", "customBgBottom": "Tło dół",
            "customCard": "Karta", "customDivider": "Rozdzielacz", "customAccent": "Akcent", "customFolder": "Folder",
            "customIsDark": "Ciemny schemat", "customApply": "Zastosuj", "customReset": "Zerowanie",
            "close": "Zamknij",
            "openCtx": "Otwórz", "finderCtx": "Pokaż w Finderze",
            "stopTip": "Odtwarzanie — kliknij, aby zatrzymać",
            "swapPanes": "Zamień panele",
            "trashSel": "Przenieś zaznaczone do Kosza",
            "trashedDone": "Wyrzucono do Kosza: %d",
            "skinsLabel": "Skórki", "importSkin": "Importuj .skn…",
            "skinBad": "Nieprawidłowy plik .skn",
            "noSkins": "Brak zaimportowanych skórek",
            "removeSkin": "Usuń tę skórkę",
            "showAllFiles": "Pokaż wszystkie pliki",
            "audioOnlyHint": "Gdy wyłączone, panele pokazują tylko foldery i pliki audio odtwarzane przez aplikację.",
            "playableFormats": "Formaty audio, które ta aplikacja może odtwarzać",
            "notImplementedFormats": "Formaty audio rozpoznawane, ale jeszcze nieobsługiwane",
            "sleepTimerLabel": "Wyłącznik czasowy",
            "sleepOff": "Wyłączony",
            "sleepMinutes": "%d minut",
            "sleepMinutesShort": "%d min",
            "miniPlayer": "Mini odtwarzacz",
            "miniIdle": "Nic nie gra",
            "miniShowMain": "Pokaż główne okno",
            "metadataTitle": "Metadane (ID3)",
            "tagTitleLabel": "Tytuł", "tagArtistLabel": "Wykonawca",
            "tagAlbumLabel": "Album", "tagTrackLabel": "Utwór",
            "tagYearLabel": "Rok", "tagGenreLabel": "Gatunek",
            "tagCommentLabel": "Komentarz",
            "tagSave": "Zapisz tagi", "tagReload": "Odśwież",
            "tagsSaved": "Tagi zapisane", "tagsSaveFailed": "Nie udało się zapisać tagów",
            "tagsUnsaved": "Niezapisane zmiany",
            "tagsFormatNote": "Tag ID3v2 — zapisywany w pliku",
            "tagsMp3Only": "Edycja tagów jest dostępna dla plików MP3 (ID3). Inne formaty mają własne systemy tagów.",
            "tagsNoSelection": "Wybierz jeden plik audio lub odtwórz utwór, aby zobaczyć jego tagi."
        ],
        .italian: [
            "left": "Sinistro", "right": "Destro",
            "up": "Cartella superiore", "refresh": "Aggiorna",
            "chooseFolder": "Scegli cartella…", "recentFolders": "Cartelle recenti",
            "name": "Nome", "size": "Dimens.", "duration": "Durata",
            "foldersN": "cartelle", "filesN": "file", "audioN": "audio",
            "playedLength": "durata %1$@ di %2$@",
            "select": "Seleziona", "deselect": "Deseleziona",
            "sortHelp": "Ordina per %@",
            "seekHelp": "Posizione brano", "volumeHelp": "Volume",
            "playAll": "Riproduci tutto",
            "playAllHelp": "Riproduce tutti i file audio della cartella in ordine",
            "notAnAudio": "Non è un file audio: %@",
            "cantDecode": "Impossibile decodificare \"%@\" — salto",
            "noPlayable": "Nessun brano riproducibile in questa cartella",
            "idleHint": "Clicca un file audio per riprodurlo — clicca ancora per fermare",
            "fromPane": "dal pannello %@",
            "prevHelp": "Precedente (riavvia il brano dopo 3 s)",
            "nextHelp": "Successivo",
            "pauseHelp": "Pausa", "resumeHelp": "Riproduci",
            "shuffleOn": "Casuale attivo", "shuffleOff": "Casuale disattivato",
            "repeatOff": "Ripetizione disattivata", "repeatAll": "Ripeti tutto",
            "repeatOne": "Ripeti brano",
            "drawerTitle": "", "drawerLibrary": "Libreria",
            "drawerEffects": "Effetti", "drawerUtilities": "Utilità",
            "newPlaylist": "Nuova", "importM3U": "Importa…",
            "playlistName": "Nome playlist", "noPlaylists":
                "Nessuna playlist. Creane una o importa un file .m3u.",
            "selectPlaylistPrompt": "Scegli una playlist per vedere i brani.",
            "playlistEmpty": "Questa playlist è ancora vuota.",
            "playlistImported": "Importata “%@” (%d brani)",
            "playlistAdded": "Aggiunti %d brani a “%@”",
            "playlistNoPlayable": "Nessun brano riproducibile in questa playlist",
            "playlistBad": "Impossibile leggere “%@”",
            "addSelection": "Aggiungi selezione", "removeEntry": "Rimuovi dalla playlist",
            "deletePlaylist": "Elimina playlist",
            "deletePlaylistConfirm": "Eliminare la playlist “%@”? Il file .m3u verrà rimosso.",
            "renamePlaylist": "Rinomina…", "missingFile": "mancante",
            "unsupportedFile": "non supportato", "missingN": "%d mancanti",
            "playFromHere": "Riproduci da qui",
            "spectrumTitle": "Spettro",
            "spectrumIdle":
                "Riproduci qualcosa per vedere lo spettro. Questa sorgente non alimenta l'analizzatore.",
            "effectsSoon":
                "Altri effetti arriveranno in questa scheda.",
            "xfTitle": "Dissolvenza",
            "xfHint": "Sovrappone la fine di un brano all'inizio del successivo. Senza interruzioni usa una sovrapposizione molto breve. Solo formati nativi.",
            "xfOff": "No", "xfGapless": "Senza pause",
            "xfThree": "3 s",
            "eqTitle": "Equalizzatore",
            "eqHint": "Dieci bande inserite nei motori interni (nativo, incorporato, MIDI). Il percorso AVPlayer di ripiego resta piatto.",
            "eqOn": "On", "eqOff": "Off", "eqReset": "Azzera",
            "eqPresets": "Predefiniti",
            "eqPreset_flat": "Piatto", "eqPreset_pop": "Pop", "eqPreset_rock": "Rock",
            "eqPreset_classical": "Classico", "eqPreset_jazz": "Jazz",
            "eqPreset_electronic": "Elettronica", "eqPreset_hiphop": "Hip-Hop",
            "eqPreset_bassboost": "Bass Boost", "eqPreset_vocalboost": "Vocal Boost",
            "eqPreset_trebleboost": "Treble Boost",
            "rgTitle": "ReplayGain",
            "rgHint": "Normalizza i brani alla stessa sonorità (EBU R128, riferimento 89 dB). Le misure sono salvate in un piccolo file .replaygain accanto a ogni brano — i file non vengono mai riscritti.",
            "rgOff": "No", "rgTrack": "Brano", "rgAlbum": "Album",
            "rgNoTrack": "Riproduci o seleziona un brano per analizzarlo.",
            "rgNotAnalysed": "Non ancora analizzato.",
            "rgScanTrack": "Analizza questo brano",
            "rgScanFolder": "Analizza cartella (album)",
            "rgRemove": "Rimuovi misura",
            "rgScanning": "Analisi…",
            "rgDoneTrack": "Analizzato “%@”",
            "rgDoneFolder": "Analizzati %d file",
            "rgFailed": "Impossibile analizzare — formato non supportato o illeggibile.",
            "rgRemoved": "Misura rimossa.",
            "rgReadout": "%1$@: guadagno %2$@ dB · brano %3$@ dB · album %4$@ dB · intensità %5$@ LUFS",
            "copyToOther": "Copia la selezione nell'altro pannello",
            "moveToOther": "Sposta la selezione nell'altro pannello",
            "selectFirst": "Seleziona prima gli elementi con i cerchi",
            "copiedDone": "Copiati %d elementi",
            "movedDone": "Spostati %d elementi",
            "opErrors": ", %d errori",
            "transferring": "Trasferimento %d di %d…",
            "dropNothing": "Niente da copiare dal trascinamento",
            "renamedConflict": "rinominato se esiste",
            "settings": "Impostazioni", "version": "Versione",
            "fontSize": "Dimensione testo", "languageLabel": "Lingua", "themeLabel": "Tema",
            "themeDark": "Scuro", "themeLight": "Chiaro",
            "themePastel": "Pastello",             "themeSteelBlue": "Blu acciaio", "themeCustom": "Personalizzato",
            "customPalette": "Tavolozza personalizzata", "customBgTop": "Sfondo alto", "customBgBottom": "Sfondo basso",
            "customCard": "Scheda", "customDivider": "Divisore", "customAccent": "Accento", "customFolder": "Cartella",
            "customIsDark": "Schema scuro", "customApply": "Applica", "customReset": "Ripristina",
            "close": "Chiudi",
            "openCtx": "Apri", "finderCtx": "Mostra nel Finder",
            "stopTip": "In riproduzione — clicca per fermare",
            "swapPanes": "Scambia pannelli",
            "trashSel": "Sposta la selezione nel Cestino",
            "trashedDone": "Cestinati %d elementi",
            "skinsLabel": "Skin", "importSkin": "Importa .skn…",
            "skinBad": "File .skn non valido",
            "noSkins": "Nessuna skin importata",
            "removeSkin": "Rimuovi questa skin",
            "showAllFiles": "Mostra tutti i file",
            "audioOnlyHint": "Se disattivata, i pannelli mostrano solo cartelle e file audio riproducibili dall'app.",
            "playableFormats": "Formati audio che questa app può riprodurre",
            "notImplementedFormats": "Formati audio riconosciuti ma non ancora implementati",
            "sleepTimerLabel": "Timer di sospensione",
            "sleepOff": "Spento",
            "sleepMinutes": "%d minuti",
            "sleepMinutesShort": "%d min",
            "miniPlayer": "Mini riproduttore",
            "miniIdle": "Nulla in riproduzione",
            "miniShowMain": "Mostra la finestra principale",
            "metadataTitle": "Metadati (ID3)",
            "tagTitleLabel": "Titolo", "tagArtistLabel": "Artista",
            "tagAlbumLabel": "Album", "tagTrackLabel": "Traccia",
            "tagYearLabel": "Anno", "tagGenreLabel": "Genere",
            "tagCommentLabel": "Commento",
            "tagSave": "Salva tag", "tagReload": "Ricarica",
            "tagsSaved": "Tag salvati", "tagsSaveFailed": "Impossibile salvare i tag",
            "tagsUnsaved": "Modifiche non salvate",
            "tagsFormatNote": "Tag ID3v2 — salvato nel file",
            "tagsMp3Only": "La modifica dei tag è disponibile per i file MP3 (ID3). Gli altri formati usano i propri sistemi di tag.",
            "tagsNoSelection": "Seleziona un file audio o riproduci un brano per vederne i tag."
        ],
        .chinese: [
            "left": "左", "right": "右",
            "up": "上一级文件夹", "refresh": "刷新",
            "chooseFolder": "选择文件夹…", "recentFolders": "最近的文件夹",
            "name": "名称", "size": "大小", "duration": "时长",
            "foldersN": "个文件夹", "filesN": "个文件", "audioN": "音频",
            "playedLength": "已播放时长 %1$@ / %2$@",
            "select": "选择", "deselect": "取消选择",
            "sortHelp": "按%@排序",
            "seekHelp": "播放位置", "volumeHelp": "音量",
            "playAll": "全部播放",
            "playAllHelp": "按排序播放此文件夹中的所有音频文件",
            "notAnAudio": "不是音频文件：%@",
            "cantDecode": "无法解码「%@」—跳过",
            "noPlayable": "此文件夹中没有可播放的文件",
            "idleHint": "点击音频文件开始播放——再次点击停止",
            "fromPane": "来自%@面板",
            "prevHelp": "上一个（3秒后重播当前曲目）",
            "nextHelp": "下一个",
            "pauseHelp": "暂停", "resumeHelp": "播放",
            "shuffleOn": "随机播放开", "shuffleOff": "随机播放关",
            "repeatOff": "不重复", "repeatAll": "全部重复",
            "repeatOne": "单曲重复",
            "drawerTitle": "", "drawerLibrary": "媒体库",
            "drawerEffects": "效果", "drawerUtilities": "工具",
            "newPlaylist": "新建", "importM3U": "导入…",
            "playlistName": "播放列表名称", "noPlaylists":
                "还没有播放列表。新建一个，或从任意位置导入 .m3u 文件。",
            "selectPlaylistPrompt": "选择一个播放列表以查看曲目。",
            "playlistEmpty": "这个播放列表还没有曲目。",
            "playlistImported": "已导入“%@”（%d 首）",
            "playlistAdded": "已向“%@”添加 %d 首曲目",
            "playlistNoPlayable": "此播放列表中没有可播放的曲目",
            "playlistBad": "无法读取“%@”",
            "addSelection": "添加所选", "removeEntry": "从播放列表移除",
            "deletePlaylist": "删除播放列表",
            "deletePlaylistConfirm": "删除播放列表“%@”？.m3u 文件将一并删除。",
            "renamePlaylist": "重命名…", "missingFile": "文件缺失",
            "unsupportedFile": "不支持", "missingN": "%d 个缺失",
            "playFromHere": "从此处播放",
            "spectrumTitle": "频谱",
            "spectrumIdle": "播放内容以查看频谱。此音源未接入分析器。",
            "effectsSoon": "此标签页未来将加入更多效果。",
            "xfTitle": "交叉淡化",
            "xfHint": "将一首歌的结尾与下一首的开头重叠。无缝模式使用极短的重叠。仅限原生格式。",
            "xfOff": "关闭", "xfGapless": "无缝",
            "xfThree": "3 秒",
            "eqTitle": "均衡器",
            "eqHint": "十个频段插入到应用内引擎（原生、内嵌、MIDI）。AVPlayer 回退路径保持平坦。",
            "eqOn": "开", "eqOff": "关", "eqReset": "重置",
            "eqPresets": "预设",
            "eqPreset_flat": "平坦", "eqPreset_pop": "流行", "eqPreset_rock": "摇滚",
            "eqPreset_classical": "古典", "eqPreset_jazz": "爵士",
            "eqPreset_electronic": "电子", "eqPreset_hiphop": "嘻哈",
            "eqPreset_bassboost": "低音增强", "eqPreset_vocalboost": "人声增强",
            "eqPreset_trebleboost": "高音增强",
            "rgTitle": "ReplayGain",
            "rgHint": "将曲目归一化到相同的响度（EBU R128，参考 89 dB）。测量结果保存在每首曲目旁的 .replaygain 小文件中——源文件不会被改写。",
            "rgOff": "关闭", "rgTrack": "曲目", "rgAlbum": "专辑",
            "rgNoTrack": "播放或选择曲目以进行分析。",
            "rgNotAnalysed": "尚未分析。",
            "rgScanTrack": "分析此曲目",
            "rgScanFolder": "分析文件夹（专辑）",
            "rgRemove": "删除测量",
            "rgScanning": "正在分析…",
            "rgDoneTrack": "已分析“%@”",
            "rgDoneFolder": "已分析 %d 个文件",
            "rgFailed": "无法分析——不支持或无法读取。",
            "rgRemoved": "已删除测量。",
            "rgReadout": "%1$@：增益 %2$@ dB · 曲目 %3$@ dB · 专辑 %4$@ dB · 响度 %5$@ LUFS",
            "copyToOther": "将选中项复制到另一侧",
            "moveToOther": "将选中项移动到另一侧",
            "selectFirst": "请先用圆圈复选框选择项目",
            "copiedDone": "已复制 %d 项",
            "movedDone": "已移动 %d 项",
            "opErrors": "，%d 个错误",
            "transferring": "正在传输第 %d 项，共 %d 项…",
            "dropNothing": "此拖放没有可复制的内容",
            "renamedConflict": "冲突时自动重命名",
            "settings": "设置", "version": "版本",
            "fontSize": "字体大小", "languageLabel": "语言", "themeLabel": "主题",
            "themeDark": "深色", "themeLight": "浅色",
            "themePastel": "粉彩",             "themeSteelBlue": "钢蓝", "themeCustom": "自定义",
            "customPalette": "自定义调色板", "customBgTop": "顶部背景", "customBgBottom": "底部背景",
            "customCard": "卡片", "customDivider": "分隔线", "customAccent": "强调色", "customFolder": "文件夹色",
            "customIsDark": "深色模式", "customApply": "应用", "customReset": "重置",
            "close": "关闭",
            "openCtx": "打开", "finderCtx": "在 Finder 中显示",
            "stopTip": "正在播放——点击停止",
            "swapPanes": "交换两侧",
            "trashSel": "将选中项移到废纸篓",
            "trashedDone": "已移到废纸篓 %d 项",
            "skinsLabel": "皮肤", "importSkin": "导入 .skn…",
            "skinBad": "无效的 .skn 文件",
            "noSkins": "尚未导入皮肤",
            "removeSkin": "删除此皮肤",
            "showAllFiles": "显示所有文件",
            "audioOnlyHint": "关闭时，面板仅列出文件夹和此应用可以播放的音频文件。",
            "playableFormats": "此应用支持的音频格式",
            "notImplementedFormats": "已识别但尚未实现的音频格式",
            "sleepTimerLabel": "睡眠定时器",
            "sleepOff": "关闭",
            "sleepMinutes": "%d 分钟",
            "sleepMinutesShort": "%d 分",
            "miniPlayer": "迷你播放器",
            "miniIdle": "当前没有播放",
            "miniShowMain": "显示主窗口",
            "metadataTitle": "元数据（ID3）",
            "tagTitleLabel": "标题", "tagArtistLabel": "艺术家",
            "tagAlbumLabel": "专辑", "tagTrackLabel": "音轨",
            "tagYearLabel": "年份", "tagGenreLabel": "流派",
            "tagCommentLabel": "注释",
            "tagSave": "保存标签", "tagReload": "重新载入",
            "tagsSaved": "标签已保存", "tagsSaveFailed": "无法保存标签",
            "tagsUnsaved": "未保存的更改",
            "tagsFormatNote": "ID3v2 标签——写入文件",
            "tagsMp3Only": "标签编辑仅支持 MP3（ID3）文件。其他格式使用各自的标签系统。",
            "tagsNoSelection": "选择一个音频文件或播放曲目以查看其标签。"
        ]
    ]
}
