import Foundation
import Combine

/// #23 MIDI instrument / sound bank.
///
/// Two engines can play a .mid/.rmi: Engine D (`AVMIDIPlayer`) is the proven
/// primary path and Engine E (`AVAudioSequencer` + `AVAudioUnitSampler`) is the
/// last-resort fallback. Both accept a SoundFont/DLS bank; AVMIDIPlayer takes
/// one at construction (`soundBankURL:`) and the sampler through
/// `loadSoundBankInstrument`. This module stores the user's choice and offers a
/// General MIDI program so a file that names no instrument can still be heard
/// with the one the listener picked.
///
/// `MIDIBankCore` is the pure half (no AVFoundation, no UserDefaults) so the
/// name table, bank sniffing and the SMF program-change injection can be tested
/// off a real device; `MIDIBankStore` is the small observable store the UI and
/// `PlayerState` share.
enum MIDIBankCore {

    /// General MIDI Level 1 melodic program names. Index == program number.
    static let gmInstruments: [String] = [
        "Acoustic Grand Piano", "Bright Acoustic Piano", "Electric Grand Piano",
        "Honky-tonk Piano", "Electric Piano 1", "Electric Piano 2",
        "Harpsichord", "Clavinet", "Celesta", "Glockenspiel", "Music Box",
        "Vibraphone", "Marimba", "Xylophone", "Tubular Bells", "Dulcimer",
        "Drawbar Organ", "Percussive Organ", "Rock Organ", "Church Organ",
        "Reed Organ", "Accordion", "Harmonica", "Tango Accordion",
        "Acoustic Guitar (nylon)", "Acoustic Guitar (steel)",
        "Electric Guitar (jazz)", "Electric Guitar (clean)",
        "Electric Guitar (muted)", "Overdriven Guitar", "Distortion Guitar",
        "Guitar Harmonics", "Acoustic Bass", "Electric Bass (finger)",
        "Electric Bass (pick)", "Fretless Bass", "Slap Bass 1", "Slap Bass 2",
        "Synth Bass 1", "Synth Bass 2", "Violin", "Viola", "Cello",
        "Contrabass", "Tremolo Strings", "Pizzicato Strings",
        "Orchestral Harp", "Timpani", "String Ensemble 1", "String Ensemble 2",
        "Synth Strings 1", "Synth Strings 2", "Choir Aahs", "Voice Oohs",
        "Synth Voice", "Orchestra Hit", "Trumpet", "Trombone", "Tuba",
        "Muted Trumpet", "French Horn", "Brass Section", "Synth Brass 1",
        "Synth Brass 2", "Soprano Sax", "Alto Sax", "Tenor Sax",
        "Baritone Sax", "Oboe", "English Horn", "Bassoon", "Clarinet",
        "Piccolo", "Flute", "Recorder", "Pan Flute", "Blown Bottle",
        "Shakuhachi", "Whistle", "Ocarina", "Lead 1 (square)",
        "Lead 2 (sawtooth)", "Lead 3 (calliope)", "Lead 4 (chiff)",
        "Lead 5 (charang)", "Lead 6 (voice)", "Lead 7 (fifths)",
        "Lead 8 (bass + lead)", "Pad 1 (new age)", "Pad 2 (warm)",
        "Pad 3 (polysynth)", "Pad 4 (choir)", "Pad 5 (bowed)",
        "Pad 6 (metallic)", "Pad 7 (halo)", "Pad 8 (sweep)", "FX 1 (rain)",
        "FX 2 (soundtrack)", "FX 3 (crystal)", "FX 4 (atmosphere)",
        "FX 5 (brightness)", "FX 6 (goblins)", "FX 7 (echoes)",
        "FX 8 (sci-fi)", "Sitar", "Banjo", "Shamisen", "Koto", "Kalimba",
        "Bagpipe", "Fiddle", "Shanai", "Tinkle Bell", "Agogo",
        "Steel Drums", "Woodblock", "Taiko Drum", "Melodic Tom",
        "Synth Drum", "Reverse Cymbal", "Guitar Fret Noise", "Breath Noise",
        "Seashore", "Bird Tweet", "Telephone Ring", "Helicopter", "Applause",
        "Gunshot"
    ]

    /// "0: Acoustic Grand Piano" for the picker.
    static func programLabel(_ program: Int) -> String {
        "\(clampProgram(program)): \(programName(program))"
    }

    static func programName(_ program: Int) -> String {
        let p = clampProgram(program)
        return gmInstruments[p]
    }

    /// Clamps into the valid MIDI program range 0...127.
    static func clampProgram(_ program: Int) -> Int {
        max(0, min(127, program))
    }

    // MARK: - Sound bank detection

    enum BankKind: String {
        case dls, sf2
    }

    /// A bank's kind from its file extension, or nil when the extension does
    /// not name a bank we can hand to CoreAudio.
    static func bankKind(forExtension ext: String) -> BankKind? {
        switch ext.lowercased() {
        case "sf2": return .sf2
        case "dls": return .dls
        default: return nil
        }
    }

    /// A bank's kind from its bytes: RIFF, then "sfbk" (SoundFont 2) or
    /// "DLS " (Downloadable Sounds) at offset 8. nil when neither matches.
    static func bankKind(of data: Data) -> BankKind? {
        let b = [UInt8](data)
        guard b.count >= 12,
              b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46 // "RIFF"
        else { return nil }
        let tag = String(bytes: b[8..<12], encoding: .ascii)
        if tag == "sfbk" { return .sf2 }
        if tag == "DLS " { return .dls }
        return nil
    }

    // MARK: - SMF program-change inspection / injection

    /// True when the Standard MIDI File contains at least one program-change
    /// event (status 0xC0...0xCF); false when it names no instrument anywhere.
    /// nil when the file is not a parsable SMF.
    static func smfHasProgramChange(_ data: Data) -> Bool? {
        guard let tracks = parseTracks(data) else { return nil }
        return tracks.tracks.contains { $0.hasProgramChange }
    }

    /// Returns a copy of the SMF with a delta-0 program change inserted at the
    /// start of every track that named no instrument, so a file with no program
    /// changes is heard with `program`. Tracks that already carry a program
    /// change are left byte-for-byte intact, so multi-instrument files keep
    /// their own arrangement. nil when the file is not a parsable SMF.
    static func smfInjectingProgramChange(_ data: Data, program: Int) -> Data? {
        let b = [UInt8](data)
        guard let tracks = parseTracks(data) else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(b.count + tracks.tracks.count * 3)
        out.append(contentsOf: b[0..<tracks.headerEnd])
        let prog = UInt8(clampProgram(program))
        for track in tracks.tracks {
            let body = Array(b[track.start..<track.end])
            if track.hasProgramChange {
                out.append(contentsOf: [0x4D, 0x54, 0x72, 0x6B]) // MTrk
                appendUInt32(&out, body.count)
                out.append(contentsOf: body)
            } else {
                let ch = UInt8(track.firstChannel ?? 0) & 0x0F
                let inject: [UInt8] = [0x00, 0xC0 | ch, prog]
                out.append(contentsOf: [0x4D, 0x54, 0x72, 0x6B]) // MTrk
                appendUInt32(&out, body.count + inject.count)
                out.append(contentsOf: inject)
                out.append(contentsOf: body)
            }
        }
        return Data(out)
    }

    // MARK: - SMF parsing helpers

    private struct TrackInfo {
        var start = 0          // offset of first event byte
        var end = 0            // offset just past the last event byte
        var hasProgramChange = false
        var firstChannel: Int? // channel of the first channel-voice event
    }

    private struct TracksInfo {
        var headerEnd = 14
        var tracks: [TrackInfo] = []
    }

    private static func parseTracks(_ data: Data) -> TracksInfo? {
        let b = [UInt8](data)
        guard b.count >= 14,
              b[0] == 0x4D, b[1] == 0x54, b[2] == 0x68, b[3] == 0x64 // MThd
        else { return nil }
        let hlen = Int(readUInt32(b, 4))
        guard hlen >= 6, 8 + hlen <= b.count else { return nil }
        let ntracks = Int(b[10]) << 8 | Int(b[11])
        var info = TracksInfo()
        info.headerEnd = 8 + hlen
        var pos = info.headerEnd
        for _ in 0..<ntracks {
            guard pos + 8 <= b.count,
                  b[pos] == 0x4D, b[pos + 1] == 0x54,
                  b[pos + 2] == 0x72, b[pos + 3] == 0x6B // MTrk
            else { return nil }
            let tlen = Int(readUInt32(b, pos + 4))
            let start = pos + 8
            guard tlen >= 0, start + tlen <= b.count else { return nil }
            let end = start + tlen
            guard let scanned = scanTrack(b, start, end) else { return nil }
            info.tracks.append(TrackInfo(start: start, end: end,
                                         hasProgramChange: scanned.hasPC,
                                         firstChannel: scanned.firstChannel))
            pos = end
        }
        return info
    }

    /// Walks one MTrk event stream. Returns whether it holds a program change
    /// and the channel of its first channel-voice event, or nil if malformed.
    private static func scanTrack(_ b: [UInt8], _ start: Int, _ end: Int)
        -> (hasPC: Bool, firstChannel: Int?)? {
        var p = start
        var prevStatus = 0
        var hasPC = false
        var firstChannel: Int?
        while p < end {
            guard let (_, afterDelta) = readVLQ(b, p, end) else { return nil }
            p = afterDelta
            guard p < end else { return nil }
            var status = Int(b[p])
            if status & 0x80 == 0 {
                guard prevStatus != 0 else { return nil } // bare running status
                status = prevStatus
            } else {
                p += 1
                if status < 0xF0 { prevStatus = status }
            }
            if status == 0xFF {
                guard p < end else { return nil }
                p += 1 // meta type
                guard let (mlen, afterLen) = readVLQ(b, p, end) else { return nil }
                p = afterLen
                guard p + Int(mlen) <= end else { return nil }
                p += Int(mlen)
            } else if status == 0xF0 || status == 0xF7 {
                guard let (slen, afterLen) = readVLQ(b, p, end) else { return nil }
                p = afterLen
                guard p + Int(slen) <= end else { return nil }
                p += Int(slen)
            } else if status >= 0x80 {
                let hi = status & 0xF0
                let dataLen = (hi == 0xC0 || hi == 0xD0) ? 1 : 2
                guard p + dataLen <= end else { return nil }
                if hi == 0xC0 { hasPC = true }
                if firstChannel == nil { firstChannel = status & 0x0F }
                p += dataLen
            } else {
                return nil
            }
        }
        return (hasPC, firstChannel)
    }

    /// Variable-length quantity. Returns (value, offset just past it).
    private static func readVLQ(_ b: [UInt8], _ from: Int, _ end: Int)
        -> (value: UInt32, next: Int)? {
        var v: UInt32 = 0
        var i = from
        var n = 0
        while i < end && n < 4 {
            let d = b[i]
            i += 1
            n += 1
            v = (v << 7) | UInt32(d & 0x7F)
            if d & 0x80 == 0 { return (v, i) }
        }
        return nil
    }

    private static func readUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16
            | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }

    private static func appendUInt32(_ out: inout [UInt8], _ v: Int) {
        out.append(UInt8((v >> 24) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8(v & 0xFF))
    }
}

/// Observable store shared by the Settings panel and `PlayerState`. Persists the
/// chosen bank path, GM program and the "name the instrument" override.
@MainActor
final class MIDIBankStore: ObservableObject {
    static let shared = MIDIBankStore()

    /// The system General MIDI DLS synth that ships with CoreAudio. macOS 26
    /// has no `/System/Library/Sound/Banks/` DLS, but this one is present.
    static let systemBankPath =
        "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls"

    private static let bankKey = "ac_midi_bank"
    private static let programKey = "ac_midi_program"
    private static let overrideKey = "ac_midi_override"

    /// The user's SoundFont/DLS path, or nil to use the system bank.
    @Published private(set) var bankPath: String? {
        didSet { UserDefaults.standard.set(bankPath, forKey: Self.bankKey) }
    }

    /// General MIDI program (0...127) offered as the default instrument.
    @Published var program: Int {
        didSet {
            let clamped = MIDIBankCore.clampProgram(program)
            if clamped != program { program = clamped; return }
            UserDefaults.standard.set(program, forKey: Self.programKey)
        }
    }

    /// When on, a file that names no instrument is played with `program`.
    @Published var overrideInstrument: Bool {
        didSet { UserDefaults.standard.set(overrideInstrument, forKey: Self.overrideKey) }
    }

    init() {
        let d = UserDefaults.standard
        bankPath = d.string(forKey: Self.bankKey)
        program = MIDIBankCore.clampProgram(d.object(forKey: Self.programKey) as? Int ?? 0)
        overrideInstrument = d.bool(forKey: Self.overrideKey)
    }

    /// The chosen bank, but only while the file still exists on disk. A bank the
    /// user moved or deleted silently falls back to the system synth.
    var customBankURL: URL? {
        guard let bankPath, !bankPath.isEmpty,
              FileManager.default.fileExists(atPath: bankPath) else { return nil }
        return URL(fileURLWithPath: bankPath)
    }

    var systemBankURL: URL { URL(fileURLWithPath: Self.systemBankPath) }

    /// What the MIDI engines should actually load.
    var resolvedBankURL: URL { customBankURL ?? systemBankURL }

    /// True when the system General MIDI synth is in use.
    var isSystemBank: Bool { customBankURL == nil }

    func setBank(_ url: URL) { bankPath = url.path }

    func resetBank() { bankPath = nil }
}
