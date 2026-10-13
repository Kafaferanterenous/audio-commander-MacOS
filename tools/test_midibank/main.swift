import Foundation

// Harness for #23 (MIDI instrument / sound bank). Compiles the shipping
// src/MIDIBank.swift, so the names, bank sniffing and SMF program-change
// injection under test are the production code, not a copy.

var checks = 0
var failures = 0

func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    checks += 1
    if condition {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

func checkEqual<T: Equatable>(_ label: String, _ got: T, _ want: T) {
    check(label, got == want, "got \(got), want \(want)")
}

// MARK: - General MIDI names / programs

checkEqual("128 GM names", MIDIBankCore.gmInstruments.count, 128)
check("no empty GM names",
      !MIDIBankCore.gmInstruments.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
checkEqual("programName 0", MIDIBankCore.programName(0), "Acoustic Grand Piano")
checkEqual("programName 24", MIDIBankCore.programName(24), "Acoustic Guitar (nylon)")
checkEqual("programName 127", MIDIBankCore.programName(127), "Gunshot")
checkEqual("programLabel", MIDIBankCore.programLabel(0), "0: Acoustic Grand Piano")
checkEqual("programLabel 127", MIDIBankCore.programLabel(127), "127: Gunshot")
checkEqual("clamp low", MIDIBankCore.clampProgram(-5), 0)
checkEqual("clamp high", MIDIBankCore.clampProgram(200), 127)
checkEqual("clamp mid", MIDIBankCore.clampProgram(64), 64)
checkEqual("clamp edge 127", MIDIBankCore.clampProgram(127), 127)
checkEqual("programName clamps", MIDIBankCore.programName(999), "Gunshot")

// MARK: - Sound bank detection

func riff(_ tag: String) -> Data {
    var d: [UInt8] = [0x52, 0x49, 0x46, 0x46]  // RIFF
    d += [0, 0, 0, 0]                           // chunk size (unchecked)
    d += Array(tag.utf8)                        // 4-char form
    return Data(d)
}

checkEqual("sf2 by extension", MIDIBankCore.bankKind(forExtension: "sf2"), .sf2)
checkEqual("SF2 by extension (case)", MIDIBankCore.bankKind(forExtension: "SF2"), .sf2)
checkEqual("dls by extension", MIDIBankCore.bankKind(forExtension: "dls"), .dls)
check("wav is not a bank", MIDIBankCore.bankKind(forExtension: "wav") == nil)
check("empty extension is not a bank", MIDIBankCore.bankKind(forExtension: "") == nil)

checkEqual("sf2 by magic", MIDIBankCore.bankKind(of: riff("sfbk")), .sf2)
checkEqual("dls by magic", MIDIBankCore.bankKind(of: riff("DLS ")), .dls)
check("wave is not a bank", MIDIBankCore.bankKind(of: riff("WAVE")) == nil)
check("truncated is not a bank",
      MIDIBankCore.bankKind(of: Data([0x52, 0x49, 0x46, 0x46])) == nil)
check("garbage is not a bank",
      MIDIBankCore.bankKind(of: Data("hello world!".utf8)) == nil)

// MARK: - SMF construction helpers

func smf(tracks: [[UInt8]], format: Int = 0, division: Int = 96) -> Data {
    var d: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6]  // MThd, len 6
    d += [UInt8((format >> 8) & 0xFF), UInt8(format & 0xFF)]
    d += [UInt8((tracks.count >> 8) & 0xFF), UInt8(tracks.count & 0xFF)]
    d += [UInt8((division >> 8) & 0xFF), UInt8(division & 0xFF)]
    for t in tracks {
        d += [0x4D, 0x54, 0x72, 0x6B]  // MTrk
        let n = t.count
        d += [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF),
              UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
        d += t
    }
    return Data(d)
}

let tempo: [UInt8] = [0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]  // 500000 us/qn
let endOfTrack: [UInt8] = [0x00, 0xFF, 0x2F, 0x00]

// A track that names its own instrument (program 40 on channel 0).
let trackWithPC: [UInt8] = tempo
    + [0x00, 0xC0, 0x28]                             // program change 40
    + [0x60, 0x90, 0x3C, 0x40, 0x60, 0x80, 0x3C, 0x40]
    + endOfTrack

// A track with no program change that uses running status for the second note.
let trackNoPC: [UInt8] = tempo
    + [0x00, 0x90, 0x3C, 0x40]                       // note on (explicit status)
    + [0x60, 0x3C, 0x40]                             // note on, running status
    + [0x60, 0x80, 0x3C, 0x40]                       // note off
    + endOfTrack

let trackTempoOnly: [UInt8] = tempo + endOfTrack

// MARK: - SMF inspection

checkEqual("detects a program change", MIDIBankCore.smfHasProgramChange(smf(tracks: [trackWithPC])), true)
checkEqual("detects no program change", MIDIBankCore.smfHasProgramChange(smf(tracks: [trackNoPC])), false)
check("running status does not fake a program change",
      MIDIBankCore.smfHasProgramChange(smf(tracks: [trackNoPC])) == false)
check("garbage is not a parsable SMF",
      MIDIBankCore.smfHasProgramChange(Data("not a midi file".utf8)) == nil)
check("truncated header is not a parsable SMF",
      MIDIBankCore.smfHasProgramChange(Data([0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6])) == nil)
check("truncated track is not a parsable SMF",
      MIDIBankCore.smfHasProgramChange(smf(tracks: [Array(trackNoPC.prefix(6))])) == nil)

// MARK: - SMF injection

let originalWithPC = smf(tracks: [trackWithPC])
let injectedWithPC = MIDIBankCore.smfInjectingProgramChange(originalWithPC, program: 12)
check("injection of a file that names an instrument is a no-op",
      injectedWithPC == originalWithPC)

let originalNoPC = smf(tracks: [trackNoPC])
let injected = MIDIBankCore.smfInjectingProgramChange(originalNoPC, program: 56)
check("injection returns data", injected != nil)
if let injected {
    let b = [UInt8](injected)
    check("injection grows by 3 bytes",
          injected.count == originalNoPC.count + 3,
          "got \(injected.count), want \(originalNoPC.count + 3)")
    // Header (14) + MTrk id/len (8) => first event byte at 22.
    check("injected program change is first, channel 0, program 56",
          b.count >= 25 && b[22] == 0x00 && b[23] == 0xC0 && b[24] == 56,
          "got \(b.count >= 25 ? "\(b[22]) \(b[23]) \(b[24])" : "short")")
    checkEqual("injected file now reports a program change",
               MIDIBankCore.smfHasProgramChange(injected), true)
    // Idempotent: a second pass sees the program change and leaves it alone.
    check("injection is idempotent",
          MIDIBankCore.smfInjectingProgramChange(injected, program: 99) == injected)
    // The original body must survive byte-for-byte after the injected event.
    let bodyBefore = Array([UInt8](originalNoPC)[22...])
    let bodyAfter = Array(b[(22 + 3)...])
    check("original track body preserved", bodyBefore == bodyAfter)
}

// Injection on a malformed file yields nil.
check("injection on garbage is nil",
      MIDIBankCore.smfInjectingProgramChange(Data("nope".utf8), program: 0) == nil)

// A format-1 file whose first track is tempo-only and second track has notes.
let multiOriginal = smf(tracks: [trackTempoOnly, trackNoPC], format: 1)
let multiInjected = MIDIBankCore.smfInjectingProgramChange(multiOriginal, program: 4)
check("multi-track injection returns data", multiInjected != nil)
if let multiInjected {
    check("multi-track injection adds 3 bytes per instrument-less track",
          multiInjected.count == multiOriginal.count + 6,
          "got \(multiInjected.count), want \(multiOriginal.count + 6)")
    checkEqual("multi-track file reports a program change",
               MIDIBankCore.smfHasProgramChange(multiInjected), true)
}

// A value already in range is not how this API is used, but clamping must hold.
if let high = MIDIBankCore.smfInjectingProgramChange(originalNoPC, program: 300) {
    let b = [UInt8](high)
    checkEqual("injected program clamps to 127", b[24], 127)
}

print("--- \(checks) checks, \(failures) failures ---")
exit(failures == 0 ? 0 : 1)
