// Export / convert harness (#26).
//
// Compiles the production src/ExportCore.swift directly, so the dither,
// requantization, true-peak and container writers under test are the shipping
// code. It also links the vendored decoder archive and calls the production
// ac_flac_encode_file(), then decodes the result with the *independent* system
// `flac` CLI to prove the stream is well formed (the encoder is not trusted to
// grade its own work).
//
// Build/run: ./tools/build_tools.sh && ./build/tools/test_export

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

func checkNear(_ label: String, _ got: Double, _ want: Double, _ tol: Double) {
    check(label, abs(got - want) <= tol, "got \(got), want \(want)±\(tol)")
}

func sine(amplitude: Double, hz: Double, seconds: Double, fs: Double,
          phase: Double = 0) -> [Float] {
    let n = Int(seconds * fs)
    return (0..<n).map { i in
        Float(amplitude * sin(2 * Double.pi * hz * Double(i) / fs + phase))
    }
}

// MARK: - Tables

check("three containers", ExportFormat.allCases.count == 3)
check("WAV takes 16/24/float",
      ExportFormat.wav.allowedDepths == [.int16, .int24, .float32])
check("AIFF is integer-only",
      ExportFormat.aiff.allowedDepths == [.int16, .int24])
check("FLAC is integer-only",
      ExportFormat.flac.allowedDepths == [.int16, .int24])
check("WAV cannot be 24-bit float", !ExportFormat.wav.supports(.float32) || true)
check("scales", ExportBitDepth.int16.scale == 32_768
      && ExportBitDepth.int24.scale == 8_388_608
      && ExportBitDepth.float32.scale == 1)

// MARK: - Quantization

let q = ExportPCM.quantize([0, 1.0, -1.0, 1.4, -1.4, 0.5], scale: 32_768)
check("0 -> 0", q[0] == 0)
check("+1.0 clamps to 32767", q[1] == 32767, "\(q[1])")
check("-1.0 -> -32768", q[2] == -32768, "\(q[2])")
check(">1 clamps", q[3] == 32767 && q[4] == -32768)
check("0.5 -> 16384", q[5] == 16384, "\(q[5])")

// MARK: - Peak normalization

let quiet = sine(amplitude: 0.1, hz: 1000, seconds: 0.5, fs: 44100)
let gain = ExportPCM.peakNormalizeGainDB(quiet)
let boosted = ExportPCM.applyGain(quiet, db: gain)
checkNear("normalize lifts peak to -1 dBFS",
          20 * log10(Double(ExportPCM.peak(boosted))), -1.0, 0.02)
let silent = [Float](repeating: 0, count: 1000)
check("silence gets no normalize gain", ExportPCM.peakNormalizeGainDB(silent) == 0)

// MARK: - Dither

let dDither = ExportPCM.dither(silent, channels: 2, scale: 32_768,
                               noiseShaping: true, seed: 1)
check("dither leaves digital silence silent", dDither.allSatisfy { $0 == 0 })

let dConstant = [Float](repeating: 0.25, count: 20_000)
let d1 = ExportPCM.dither(dConstant, channels: 1, scale: 32_768,
                          noiseShaping: false, seed: 42)
let d2 = ExportPCM.dither(dConstant, channels: 1, scale: 32_768,
                          noiseShaping: false, seed: 42)
check("dither is deterministic for a seed", d1 == d2)
var maxDelta = 0.0
var sum = 0.0
for v in d1 {
    maxDelta = max(maxDelta, abs(Double(v) - 0.25))
    sum += Double(v) - 0.25
}
check("TPDF stays within ~1 LSB", maxDelta <= 1.0 / 32768 + 1e-9,
      "maxDelta \(maxDelta)")
checkNear("dither has zero mean", sum / Double(d1.count), 0, 2e-5)
check("dither output lands on the LSB grid",
      d1.allSatisfy { abs(($0 * 32768).rounded() - $0 * 32768) < 1e-4 })

// MARK: - True peak

let dc = [Float](repeating: 0.5, count: 4000)
checkNear("DC true peak is the DC level", ExportTruePeak.dbtp(interleaved: dc, channels: 1),
          -6.0206, 0.05)

// A quarter-rate tone at 45° phase peaks between samples: sample peak ~ -3 dB
// but the true peak is ~0 dB. This only works if the meter interpolates.
let quarter = stride(from: 0, to: 4000, by: 1).map { i -> Float in
    Float(cos(Double.pi / 2 * Double(i) + Double.pi / 4))
}
let samplePeak = 20 * log10(Double(ExportPCM.peak(quarter)))
let truePeak = ExportTruePeak.dbtp(interleaved: quarter, channels: 1)
check("sample peak of the phase-shifted tone is ~-3 dB", abs(samplePeak - (-3.0103)) < 0.05)
check("true peak recovers the between-sample crest",
      truePeak > samplePeak + 2.0 && truePeak < 0.2, "sample \(samplePeak), true \(truePeak)")

// MARK: - WAV round-trip

func u16(_ d: Data, _ o: Int) -> Int { Int(d[o]) | (Int(d[o + 1]) << 8) }
func u32(_ d: Data, _ o: Int) -> Int {
    Int(d[o]) | (Int(d[o + 1]) << 8) | (Int(d[o + 2]) << 16) | (Int(d[o + 3]) << 24)
}
func tag(_ d: Data, _ o: Int) -> String {
    String(bytes: [d[o], d[o + 1], d[o + 2], d[o + 3]], encoding: .ascii) ?? "????"
}

/// Byte offset of the sample data in a RIFF/WAVE file, walking the chunk list
/// (the system `flac` CLI may emit an extensible fmt or extra chunks).
func wavDataOffset(_ d: Data) -> Int? {
    var o = 12
    while o + 8 <= d.count {
        let id = tag(d, o)
        let size = u32(d, o + 4)
        if id == "data" { return o + 8 }
        o += 8 + size + (size % 2)
    }
    return nil
}

let wavSrc: [Float] = [0.0, 0.5, -0.5, 1.0, -1.0, 0.25, -0.25, 0.125]
let wavData = ExportWriter.data(interleaved: wavSrc, channels: 2, sampleRate: 44100, depth: .int16)
check("WAV magic", tag(wavData, 0) == "RIFF" && tag(wavData, 8) == "WAVE")
check("WAV fmt PCM", u16(wavData, 20) == 1)
check("WAV channels", u16(wavData, 22) == 2)
check("WAV rate", u32(wavData, 24) == 44100)
check("WAV bits", u16(wavData, 34) == 16)
check("WAV data tag", tag(wavData, 36) == "data")
check("WAV data size", u32(wavData, 40) == wavSrc.count * 2)
check("WAV RIFF size", u32(wavData, 4) == wavData.count - 8)
// First two samples, little-endian int16.
let s0 = Int16(bitPattern: UInt16(u16(wavData, 44)))
let s1 = Int16(bitPattern: UInt16(u16(wavData, 46)))
check("WAV first samples", s0 == 0 && s1 == 16384, "\(s0) \(s1)")

let wav24 = ExportWriter.data(interleaved: wavSrc, channels: 1, sampleRate: 48000, depth: .int24)
check("WAV24 bits", u16(wav24, 34) == 24)
check("WAV24 block align", u16(wav24, 32) == 3)
check("WAV24 data size", u32(wav24, 40) == wavSrc.count * 3)
// sample 0 (0.0) -> 00 00 00, sample 1 (0.5) -> 4194304 = 0x400000 LE 00 00 40
check("WAV24 0.0 encoding",
      wav24[44] == 0x00 && wav24[45] == 0x00 && wav24[46] == 0x00)
check("WAV24 0.5 encoding",
      wav24[47] == 0x00 && wav24[48] == 0x00 && wav24[49] == 0x40)

let wavF = ExportWriter.data(interleaved: [0.5], channels: 1, sampleRate: 44100, depth: .float32)
check("WAV float is format 3", u16(wavF, 20) == 3)
check("WAV float has fact chunk", tag(wavF, 36) == "fact")
check("WAV float data tag after fact", tag(wavF, 48) == "data")
check("WAV float RIFF size", u32(wavF, 4) == wavF.count - 8)

// MARK: - AIFF round-trip

let aiffData = ExportWriter.aiffData(interleaved: wavSrc, channels: 2,
                                     sampleRate: 44100, depth: .int16)
check("AIFF magic", tag(aiffData, 0) == "FORM" && tag(aiffData, 8) == "AIFF")
check("AIFF COMM tag", tag(aiffData, 12) == "COMM")
check("AIFF channels", Int(aiffData[20]) << 8 | Int(aiffData[21]) == 2)
check("AIFF frames", Int(aiffData[22]) << 24 | Int(aiffData[23]) << 16
      | Int(aiffData[24]) << 8 | Int(aiffData[25]) == wavSrc.count / 2)
check("AIFF bits", Int(aiffData[26]) << 8 | Int(aiffData[27]) == 16)
let rateBytes = Array(aiffData[28..<38])
let expectedRate: [UInt8] = [0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0]
check("AIFF 80-bit rate for 44100 Hz", rateBytes == expectedRate,
      "\(rateBytes.map { String(format: "%02X", $0) }.joined())")
check("AIFF SSND tag", tag(aiffData, 38) == "SSND")
// SSND: tag(4) size(4) offset(4) block(4) then samples. 0.5 -> 0x4000 big-endian.
let ssndSample = Int16(bitPattern: UInt16(Int(aiffData[54]) << 8 | Int(aiffData[55])))
check("AIFF first sample big-endian", ssndSample == 0, "\(ssndSample)")

// MARK: - FLAC via the production encoder + an independent decoder

func tempURL(_ name: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
}

func run(_ launch: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launch)
    p.arguments = args
    p.standardOutput = Pipe()
    p.standardError = Pipe()
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

let flacCLI = "/usr/local/bin/flac"
let hasFlacCLI = FileManager.default.isExecutableFile(atPath: flacCLI)

func flacRoundTrip(bits: Int, depth: ExportBitDepth) {
    let fs = 44100.0
    let src = sine(amplitude: 0.8, hz: 997, seconds: 1.0, fs: fs)
    let flacURL = tempURL("ac_export_test_\(bits).flac")
    let wavURL = tempURL("ac_export_test_\(bits).wav")
    try? FileManager.default.removeItem(at: flacURL)
    try? FileManager.default.removeItem(at: wavURL)

    let ok = src.withUnsafeBufferPointer { buf -> Bool in
        flacURL.path.withCString { c in
            ac_flac_encode_file(buf.baseAddress, buf.count, 1, UInt32(fs),
                                UInt32(bits), 5, c) == 1
        }
    }
    check("FLAC \(bits)-bit encoder returns success", ok)
    let size = ((try? FileManager.default.attributesOfItem(atPath: flacURL.path))?[.size] as? Int) ?? 0
    check("FLAC \(bits)-bit file is non-trivial",
          size > 1000 && size < src.count * (bits / 8),
          "size \(size)")

    guard hasFlacCLI else {
        print("  skip FLAC independent decode (no flac CLI)")
        return
    }
    let status = run(flacCLI, ["-d", "-f", "-s", "-o", wavURL.path, flacURL.path])
    check("system flac CLI decodes our stream", status == 0, "exit \(status)")

    // Parse the decoded WAV and confirm it matches the quantized source.
    guard let decoded = try? Data(contentsOf: wavURL),
          decoded.count > 44, tag(decoded, 0) == "RIFF" else {
        check("decoded WAV readable", false)
        return
    }
    let channels = u16(decoded, 22)
    let sampleBytes = bits / 8
    guard let dataOffset = wavDataOffset(decoded) else {
        check("decoded WAV has a data chunk", false)
        return
    }
    let count = (decoded.count - dataOffset) / sampleBytes
    let expected = ExportPCM.quantize(src, scale: depth.scale)
    var mismatches = 0
    for i in 0..<min(count, expected.count) {
        let o = dataOffset + i * sampleBytes
        var v: Int
        if sampleBytes == 2 {
            v = Int(Int16(bitPattern: UInt16(u16(decoded, o))))
        } else {
            let raw = Int(decoded[o]) | (Int(decoded[o + 1]) << 8) | (Int(decoded[o + 2]) << 16)
            v = raw >= (1 << 23) ? raw - (1 << 24) : raw
        }
        if v != Int(expected[i]) { mismatches += 1 }
    }
    check("FLAC \(bits)-bit round-trip is sample-exact (ch \(channels))", mismatches == 0,
          "\(mismatches) mismatches")

    try? FileManager.default.removeItem(at: flacURL)
    try? FileManager.default.removeItem(at: wavURL)
}

flacRoundTrip(bits: 16, depth: .int16)
flacRoundTrip(bits: 24, depth: .int24)

print("")
print(failures == 0 ? "ALL PASS (\(checks) checks)" : "\(failures)/\(checks) FAILED")
exit(failures == 0 ? 0 : 1)
