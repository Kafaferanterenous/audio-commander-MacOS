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
    case dark, light, pastel, blue
    var id: String { rawValue }

    var localizedNameKey: String {
        switch self {
        case .dark: return "themeDark"
        case .light: return "themeLight"
        case .pastel: return "themePastel"
        case .blue: return "themeBlue"
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
                bgTop: Color(red: 0.99, green: 0.93, blue: 0.96),
                bgBottom: Color(red: 0.91, green: 0.88, blue: 0.99),
                cardOpacityFill: Color.white.opacity(0.50),
                divider: Color(red: 0.72, green: 0.60, blue: 0.88),
                accent: Color(red: 0.63, green: 0.42, blue: 0.85),
                folderColor: Color(red: 0.55, green: 0.68, blue: 0.95),
                colorScheme: .light)
        case .blue:
            return ThemePalette(
                bgTop: Color(red: 0.035, green: 0.10, blue: 0.21),
                bgBottom: Color(red: 0.07, green: 0.17, blue: 0.33),
                cardOpacityFill: Color.white.opacity(0.06),
                divider: Color.white.opacity(0.16),
                accent: Color(red: 0.44, green: 0.72, blue: 1.00),
                folderColor: Color(red: 0.52, green: 0.80, blue: 0.98),
                colorScheme: .dark)
        }
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
        loadSkinsFromDisk()
    }

    func scaled(_ size: CGFloat) -> Font {
        .system(size: size * fontScale)
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
            "drawerTitle": "Inspector", "drawerLibrary": "Library",
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
            "effectsSoon":
                "Equalizer, ReplayGain and the spectrum analyzer are planned for the Effects tab (#16–#19).",
            "utilitiesSoon":
                "The sleep timer lives here. The metadata editor arrives with #21.",
            "copyToOther": "Copy selection to the other pane",
            "moveToOther": "Move selection to the other pane",
            "selectFirst": "Select items with the circle checkboxes first",
            "copiedDone": "Copied %d item(s)",
            "movedDone": "Moved %d item(s)",
            "opErrors": ", %d error(s)",
            "transferring": "Transferring %d of %d…",
            "renamedConflict": "renamed on conflict",
            "settings": "Settings", "version": "Version",
            "fontSize": "Font size", "languageLabel": "Language", "themeLabel": "Theme",
            "themeDark": "Dark", "themeLight": "Light",
            "themePastel": "Pastel", "themeBlue": "Blue",
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
            "sleepMinutes": "%d minutes"
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
            "drawerTitle": "Inspektor", "drawerLibrary": "Biblioteka",
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
            "effectsSoon":
                "Korektor, ReplayGain i analizator widma pojawią się w zakładce Efekty (#16–#19).",
            "utilitiesSoon":
                "Tu znajduje się licznik usypiania. Edytor metadanych pojawi się w #21.",
            "copyToOther": "Kopiuj zaznaczone do drugiego panelu",
            "moveToOther": "Przenieś zaznaczone do drugiego panelu",
            "selectFirst": "Najpierw zaznacz pliki kółkami wyboru",
            "copiedDone": "Skopiowano: %d",
            "movedDone": "Przeniesiono: %d",
            "opErrors": ", błędy: %d",
            "transferring": "Przesyłanie %d z %d…",
            "renamedConflict": "zmieniono nazwę przy konflikcie",
            "settings": "Ustawienia", "version": "Wersja",
            "fontSize": "Rozmiar czcionki", "languageLabel": "Język", "themeLabel": "Motyw",
            "themeDark": "Ciemny", "themeLight": "Jasny",
            "themePastel": "Pastelowy", "themeBlue": "Niebieski",
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
            "sleepMinutes": "%d minut"
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
            "drawerTitle": "Inspector", "drawerLibrary": "Libreria",
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
            "effectsSoon":
                "Equalizzatore, ReplayGain e analizzatore di spettro arriveranno nella scheda Effetti (#16–#19).",
            "utilitiesSoon":
                "Qui si trova il timer di sospensione. L'editor dei metadati arriva con #21.",
            "copyToOther": "Copia la selezione nell'altro pannello",
            "moveToOther": "Sposta la selezione nell'altro pannello",
            "selectFirst": "Seleziona prima gli elementi con i cerchi",
            "copiedDone": "Copiati %d elementi",
            "movedDone": "Spostati %d elementi",
            "opErrors": ", %d errori",
            "transferring": "Trasferimento %d di %d…",
            "renamedConflict": "rinominato se esiste",
            "settings": "Impostazioni", "version": "Versione",
            "fontSize": "Dimensione testo", "languageLabel": "Lingua", "themeLabel": "Tema",
            "themeDark": "Scuro", "themeLight": "Chiaro",
            "themePastel": "Pastello", "themeBlue": "Blu",
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
            "sleepMinutes": "%d minuti"
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
            "drawerTitle": "检查器", "drawerLibrary": "媒体库",
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
            "effectsSoon":
                "均衡器、ReplayGain 和频谱分析器将在“效果”标签页中提供（#16–#19）。",
            "utilitiesSoon":
                "睡眠定时器位于此处。标签编辑器将随 #21 一同加入。",
            "copyToOther": "将选中项复制到另一侧",
            "moveToOther": "将选中项移动到另一侧",
            "selectFirst": "请先用圆圈复选框选择项目",
            "copiedDone": "已复制 %d 项",
            "movedDone": "已移动 %d 项",
            "opErrors": "，%d 个错误",
            "transferring": "正在传输第 %d 项，共 %d 项…",
            "renamedConflict": "冲突时自动重命名",
            "settings": "设置", "version": "版本",
            "fontSize": "字体大小", "languageLabel": "语言", "themeLabel": "主题",
            "themeDark": "深色", "themeLight": "浅色",
            "themePastel": "粉彩", "themeBlue": "蓝色",
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
            "sleepMinutes": "%d 分钟"
        ]
    ]
}
