// ReplayGain harness (#19).
//
// Compiles the production src/ReplayGain.swift directly, so the K-weighting,
// block energy gating and loudness mapping under test are the shipping code.
// The AVFoundation decode paths (AVAudioFile + PullDecoder) and the sidecar
// store live in src/ReplayGainStore.swift and cannot run hostless; the pure
// measurement is what gets pinned here, driven by synthetic PCM.
//
// Build/run: ./tools/build_tools.sh && ./build/tools/test_replaygain

import Foundation

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

func checkNear(_ label: String, _ got: Double, _ want: Double, _ tol: Double,
               _ detail: String = "") {
    check(label, abs(got - want) <= tol,
          "\(detail.isEmpty ? "" : detail + " — ")got \(got), want \(want)±\(tol)")
}

func sine(amplitude: Double, hz: Double, seconds: Double, fs: Double) -> [Float] {
    let n = Int(seconds * fs)
    return (0..<n).map { i in Float(amplitude * sin(2 * Double.pi * hz * Double(i) / fs)) }
}

// MARK: - Constants and parameters

check("reference level is 89 dB", ReplayGain.referenceLevel == 89)
checkNear("absolute gate is -70 LUFS", ReplayGain.absoluteGate, -70, 0)
check("block length is 400 ms", ReplayGain.blockSeconds == 0.4)
check("k-offset is within BS.1770 spec", abs(ReplayGain.kOffset - (-0.691)) < 0.001)

let fs = 44100.0
let full = sine(amplitude: 1.0, hz: 1000, seconds: 2.0, fs: fs) // 88_200 samples

// MARK: - Silence

let silence = [Float](repeating: 0, count: 88_200)
let silentResult = ReplayGain.measure(mono: silence, sampleRate: fs)
check("silence has no loudness", silentResult.loudnessLUFS == nil)
check("silence gain is 0", silentResult.gainDB == 0)
check("silence peak is 0", silentResult.peak == 0)

// MARK: - Block energies on a stationary signal

let energies = ReplayGain.blockEnergies(mono: full, sampleRate: fs)
check("2.0 s @44.1k yields 17 blocks (400 ms, 75% overlap)",
      energies.count == 17, "count \(energies.count)")
// A pure tone is stationary, so every block has the same energy.
let mean = energies.reduce(0, +) / Double(energies.count)
let spread = energies.map { abs($0 - mean) / max(mean, 1e-12) }.max() ?? 0
check("stationary tone: block energies within 2% of each other", spread < 0.02,
      "spread \(spread)")
check("block energies are positive", mean > 0)

// MARK: - Full-scale tone loudness

let fsResult = ReplayGain.measure(mono: full, sampleRate: fs)
if let lufs = fsResult.loudnessLUFS {
    check("full-scale 1 kHz measures near -3 LUFS",
          lufs > -3.9 && lufs < -2.7, "\(lufs) LUFS")
    checkNear("gain is exactly reference minus loudness",
              fsResult.gainDB, 89 - lufs, 1e-9)
} else {
    check("full-scale 1 kHz has loudness", false, "nil")
}
checkNear("full-scale peak is 1.0", Double(fsResult.peak), 1.0, 0.001)

// MARK: - Amplitude scaling (loudness must move 6 LU per doubling of amplitude)

let half = sine(amplitude: 0.5, hz: 1000, seconds: 2.0, fs: fs)
let double = sine(amplitude: 2.0, hz: 1000, seconds: 2.0, fs: fs)
let halfResult = ReplayGain.measure(mono: half, sampleRate: fs)
let doubleResult = ReplayGain.measure(mono: double, sampleRate: fs)
if let f = fsResult.loudnessLUFS, let h = halfResult.loudnessLUFS,
   let d = doubleResult.loudnessLUFS {
    checkNear("halving amplitude lowers loudness 6.02 LU",
              h, f - 6.0206, 0.05, "full \(f), half \(h)")
    checkNear("doubling amplitude raises loudness 6.02 LU",
              d, f + 6.0206, 0.05, "full \(f), double \(d)")
} else {
    check("amplitude-scaled tones have loudness", false)
}
checkNear("half-amplitude peak is 0.5", Double(halfResult.peak), 0.5, 0.001)
checkNear("double-amplitude peak is 2.0", Double(doubleResult.peak), 2.0, 0.001)

// MARK: - Too-short signal

let burst = sine(amplitude: 1.0, hz: 1000, seconds: 0.2, fs: fs)
let burstResult = ReplayGain.measure(mono: burst, sampleRate: fs)
check("signal shorter than one block has no loudness", burstResult.loudnessLUFS == nil)
check("short signal gain is 0", burstResult.gainDB == 0)

// MARK: - Sample-rate invariance (a 1 kHz tone at 48 kHz must land close)

let fs48 = 48000.0
let full48 = sine(amplitude: 1.0, hz: 1000, seconds: 2.0, fs: fs48)
let fs48Result = ReplayGain.measure(mono: full48, sampleRate: fs48)
if let a = fsResult.loudnessLUFS, let b = fs48Result.loudnessLUFS {
    checkNear("48 kHz closely tracks 44.1 kHz", b, a, 0.3, "44.1k \(a), 48k \(b)")
} else {
    check("48 kHz tone has loudness", false)
}

// MARK: - Gating: a quiet music-like tail still measures, ambient hush does not

// A loud 3 s signal followed by soft 1 s tail: everything clears the gate.
var withTail = sine(amplitude: 1.0, hz: 1000, seconds: 3.0, fs: fs)
withTail += sine(amplitude: 0.001, hz: 1000, seconds: 1.0, fs: fs)
let tailResult = ReplayGain.measure(mono: withTail, sampleRate: fs)
check("signal with quiet tail still measures", tailResult.loudnessLUFS != nil)

// MARK: - Deep sub-gate content alone is nil (so quiet the blocks sit under
// the -70 LUFS absolute gate).

let hush = sine(amplitude: 1e-5, hz: 1000, seconds: 2.0, fs: fs)
let hushResult = ReplayGain.measure(mono: hush, sampleRate: fs)
check("sub-gate content has no loudness", hushResult.loudnessLUFS == nil)

// MARK: - Decode-path guard (pure core API surface used by the store)

check("mode cases round-trip through raw values",
      ReplayGainMode(rawValue: ReplayGainMode.off.rawValue) == .off
          && ReplayGainMode(rawValue: ReplayGainMode.track.rawValue) == .track
          && ReplayGainMode(rawValue: ReplayGainMode.album.rawValue) == .album
          && ReplayGainMode(rawValue: "bogus") == nil)
check("mode title keys exist", ReplayGainMode.allCases.allSatisfy { !$0.titleKey.isEmpty })

print("--- \(checks) checks, \(failures) failures ---")
exit(failures == 0 ? 0 : 1)