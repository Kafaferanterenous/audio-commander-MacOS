// 10-band EQ harness (#17).
//
// Compiles the production src/EqualizerCore math directly, so the coefficient
// tables and the response curves under test are the shipping code. The audio
// path itself is one AVAudioUnitEQ inserted per in-app engine (native,
// embedded, midi-E), which cannot be exercised in a hostless harness; the
// peaks/cuts and their semblance of the AU's settings are what gets pinned.
//
// Build/run: ./tools/build_tools.sh && ./tools/test_equalizer

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

// MARK: - Band table

check("ten bands", EqualizerCore.bandCount == 10, "count \(EqualizerCore.bandCount)")
check("band centers ascending and finite",
      EqualizerCore.centers.count == 10
          && EqualizerCore.centers.allSatisfy { $0.isFinite && $0 > 0 }
          && zip(EqualizerCore.centers, EqualizerCore.centers.dropFirst()).allSatisfy { $0 < $1 })
check("lowest is 31 Hz, highest 16 kHz",
      EqualizerCore.centers.first == 31 && EqualizerCore.centers.last == 16_000)
check("gains clamp [-12, 12]", EqualizerCore.minGain == -12 && EqualizerCore.maxGain == 12)
checkNear("clamp high", EqualizerCore.clampGain(20), 12, 0)
checkNear("clamp low", EqualizerCore.clampGain(-30), -12, 0)
checkNear("clamp inside", EqualizerCore.clampGain(4.5), 4.5, 0)

// MARK: - Coefficient guard rails

check("nil on zero Q", EqualizerCore.peakingCoefficients(sampleRate: 44100, center: 1000, q: 0, db: 0) == nil)
check("nil on negative Q", EqualizerCore.peakingCoefficients(sampleRate: 44100, center: 1000, q: -1, db: 0) == nil)
check("nil on zero rate", EqualizerCore.peakingCoefficients(sampleRate: 0, center: 1000, q: 1, db: 0) == nil)
check("nil on zero center", EqualizerCore.peakingCoefficients(sampleRate: 44100, center: 0, q: 1, db: 0) == nil)
check("five coefficients", EqualizerCore.peakingCoefficients(sampleRate: 44100, center: 1000, q: 1, db: 6)?.count == 5)

// MARK: - Response curves

let sr = 44100.0
let c = 1000.0

// 0 dB is the identity: response 1.0 at every frequency.
for f in [1.0, 100.0, c, 4400.0, 19_999.0] {
    checkNear("0 dB identity at \(Int(f)) Hz", EqualizerCore.responseAt(sampleRate: sr, center: c, q: 1, db: 0, frequency: f), 1, 0.0001)
}

// A boost peaks at the center and returns to ~unity far away.
let boostCenter = EqualizerCore.responseAt(sampleRate: sr, center: c, q: 1, db: 12, frequency: c)
let boostFar = EqualizerCore.responseAt(sampleRate: sr, center: c, q: 1, db: 12, frequency: c / 50)
check("boosts above 1 at center", boostCenter > 1.01, "got \(boostCenter)")
check("boost returns to ~unity far away", abs(boostFar - 1) < 0.02, "got \(boostFar)")
checkNear("12 dB boost peaks near 10^(12/20)", boostCenter, pow(10, 12.0 / 20), 0.25, "got \(boostCenter)")

// A cut is the reciprocal of the boost (peaking filter symmetry).
let cutCenter = EqualizerCore.responseAt(sampleRate: sr, center: c, q: 1, db: -12, frequency: c)
check("cuts below 1 at center", cutCenter < 0.99, "got \(cutCenter)")
checkNear("boost×cut is 1 at center", boostCenter * cutCenter, 1, 0.05)

// Sweep near the center shows the expected band shape without depending on the
// exact Q convention the AU uses.
let atBandEdge = EqualizerCore.responseAt(sampleRate: sr, center: c, q: 1, db: 12, frequency: c / 1.5)
check("boost smaller one band away", atBandEdge > 1 && atBandEdge < boostCenter,
      "edge \(atBandEdge), center \(boostCenter)")

// Negative gain never goes below -12 dB worth of linear attenuation at center.
let maxCut = EqualizerCore.responseAt(sampleRate: sr, center: c, q: 1, db: -60, frequency: c)
checkNear("clamped cut peaks at -12 dB", maxCut, pow(10, -12.0 / 20), 0.01, "got \(maxCut)")

// MARK: - Presets

check("ten presets", EqualizerCore.presets.count == 10,
      "count \(EqualizerCore.presets.count)")
check("preset ids are unique and non-empty",
      EqualizerCore.presets.map(\.id).allSatisfy { !$0.isEmpty }
          && Set(EqualizerCore.presets.map(\.id)).count == EqualizerCore.presets.count)
for preset in EqualizerCore.presets {
    let gains = preset.gains
    check("preset \(preset.id) has 10 gains",
          gains.count == EqualizerCore.bandCount, "count \(gains.count)")
    check("preset \(preset.id) gains in [-12, 12]",
          gains.allSatisfy { $0.isFinite
              && $0 >= EqualizerCore.minGain && $0 <= EqualizerCore.maxGain })
    check("preset \(preset.id) lookup round-trips",
          EqualizerCore.preset(id: preset.id)?.id == preset.id)
}
check("flat preset is all zeros",
      EqualizerCore.preset(id: "flat")?.gains.allSatisfy { $0 == 0 } == true)
check("unknown preset id is nil", EqualizerCore.preset(id: "bogus") == nil)
// Boosting presets must stay gentle enough not to push the summed curve into
// clipping: the loudest preset should leave headroom for the ±12 dB overdub.
check("no preset requires > +6 dB on any single band",
      EqualizerCore.presets.allSatisfy { p in p.gains.allSatisfy { $0 <= 6 } })
check("some preset actually boosts and cuts",
      EqualizerCore.presets.contains { p in p.gains.contains { $0 > 3 } }
          && EqualizerCore.presets.contains { p in p.gains.contains { $0 < -2 } })

print("--- \(checks) checks, \(failures) failures ---")
exit(failures == 0 ? 0 : 1)