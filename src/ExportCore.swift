import Foundation

// Export / convert (#26). Turns anything the app can play — native CoreAudio
// formats and the embedded exotic ones (trackers, Vorbis, WavPack, Ogg FLAC,
// VOC, DSD) — into an interchangeable file: WAV, AIFF or native FLAC.
//
// This file is deliberately free of AVFoundation: it is the pure half that the
// tools/test_export harness compiles and pins. The decode side (AVAudioFile +
// PullDecoder) and the libFLAC call live in src/Exporter.swift.
//
// The DSP and the container writers here mirror the way SoundCraft (the Rust
// DAW) bounces: TPDF dither with optional first-order error-feedback noise
// shaping, peak normalization, and a loudness report (integrated LUFS + true
// peak) so an export can be checked rather than just trusted.

enum ExportFormat: String, CaseIterable, Identifiable {
    case wav
    case aiff
    case flac

    var id: String { rawValue }
    var fileExtension: String { rawValue }
    var titleKey: String { "exportFormat_" + rawValue }

    /// Which sample depths this container can hold. AIFF here is integer-only
    /// (float would need the AIFC shell); FLAC is integer by definition (4..24
    /// bits, so the useful depths are 16 and 24).
    var allowedDepths: [ExportBitDepth] {
        switch self {
        case .wav: return [.int16, .int24, .float32]
        case .aiff: return [.int16, .int24]
        case .flac: return [.int16, .int24]
        }
    }

    func supports(_ depth: ExportBitDepth) -> Bool { allowedDepths.contains(depth) }
}

enum ExportBitDepth: String, CaseIterable, Identifiable {
    case int16
    case int24
    case float32

    var id: String { rawValue }
    var bits: Int {
        switch self {
        case .int16: return 16
        case .int24: return 24
        case .float32: return 32
        }
    }
    var isFloat: Bool { self == .float32 }
    var bytesPerSample: Int { bits / 8 }
    var titleKey: String { "exportDepth_" + rawValue }

    var shortLabel: String {
        switch self {
        case .int16: return "16-bit"
        case .int24: return "24-bit"
        case .float32: return "32-bit float"
        }
    }

    /// Full-scale integer value: sample = round(x * scale), x in [-1, 1].
    /// 16 -> 32768, 24 -> 8388608. Float re-uses the raw value (scale 1).
    var scale: Double {
        switch self {
        case .int16: return 32_768
        case .int24: return 8_388_608
        case .float32: return 1
        }
    }
}

struct ExportOptions: Equatable {
    var format: ExportFormat = .flac
    var depth: ExportBitDepth = .int16
    /// Noise is added before requantizing to an integer depth.
    var dither: Bool = true
    /// First-order error feedback pushed out of the audible band.
    var noiseShaping: Bool = true
    /// Peak-normalize to just below full scale.
    var normalize: Bool = false
    /// Apply the track's stored ReplayGain gain when one exists.
    var replayGain: Bool = false

    /// A stable, human-meaningful description used in the report and filenames.
    var summary: String { "\(format.rawValue.uppercased()) · \(depth.shortLabel)" }
}

/// Stereo/multichannel gain, dither, requantization and true-peak measurement.
/// Pure math: no framework, no allocation surprises, deterministic given a seed.
enum ExportPCM {
    static let normalizeCeilingDBFS = -1.0

    static func peak(_ samples: [Float]) -> Float {
        var m: Float = 0
        for s in samples {
            let a = abs(s)
            if a > m { m = a }
        }
        return m
    }

    /// dB to add so the loudest sample sits at `ceilingDBFS`. Zero for silence.
    static func peakNormalizeGainDB(_ samples: [Float],
                                    ceilingDBFS: Double = normalizeCeilingDBFS) -> Double {
        let p = Double(peak(samples))
        guard p > 1e-7 else { return 0 }
        return ceilingDBFS - 20 * log10(p)
    }

    static func applyGain(_ samples: [Float], db: Double) -> [Float] {
        guard db.isFinite, db != 0 else { return samples }
        let g = Float(pow(10, db / 20))
        return samples.map { $0 * g }
    }

    /// xorshift64* — small, fast, and good enough for dither. Seeded per export
    /// so a re-run of the same file is byte-identical.
    struct RNG {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
        mutating func next() -> UInt64 {
            var x = state
            x ^= x << 13
            x ^= x >> 7
            x ^= x << 17
            state = x
            return x
        }
        /// Uniform in [-1, 1).
        mutating func bipolar() -> Double {
            Double(next() >> 11) / Double(UInt64(1) << 53) * 2 - 1
        }
    }

    /// TPDF dither (triangular, 2 LSB peak-to-peak) plus optional first-order
    /// error feedback, applied in the float domain. The result is already a
    /// multiple of the target LSB, so the writer's rounding is exact. Digital
    /// silence stays silent (no dither on true zero).
    static func dither(_ samples: [Float], channels: Int, scale: Double,
                       noiseShaping: Bool, seed: UInt64) -> [Float] {
        guard scale > 1, channels > 0, !samples.isEmpty else { return samples }
        let lsb = 1.0 / scale
        var rng = RNG(seed: seed)
        var errors = [Double](repeating: 0, count: channels)
        var out = [Float](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let ch = i % channels
            let x = Double(samples[i])
            if x == 0 {
                out[i] = 0
                errors[ch] = 0
                continue
            }
            let v = noiseShaping ? x - errors[ch] : x
            let d = (rng.bipolar() + rng.bipolar()) * 0.5 * lsb
            let q = ((v + d) / lsb).rounded() * lsb
            errors[ch] = q - v
            out[i] = Float(q)
        }
        return out
    }

    /// Final float -> integer conversion with clipping. `lo..hi` is the signed
    /// range for the depth (e.g. -32768..32767).
    static func quantize(_ samples: [Float], scale: Double) -> [Int32] {
        guard scale > 1 else { return samples.map { Int32($0) } }
        let hi = Int32(scale) - 1
        let lo = -Int32(scale)
        return samples.map { s in
            var q = (Double(s) * scale).rounded()
            if q < Double(lo) { q = Double(lo) }
            else if q > Double(hi) { q = Double(hi) }
            return Int32(q)
        }
    }
}

/// 4× oversampled true-peak meter (the same idea as SoundCraft's BS.1770
/// meter and the ITU-R BS.1770-4 annex). The signal is zero-stuffed by 4 and
/// run through a windowed-sinc low-pass in polyphase form, so a sample peak
/// that misses the true crest between samples is caught.
enum ExportTruePeak {
    static let phases = 4
    static let tapsPerPhase = 16
    static let filterLength = phases * tapsPerPhase

    /// Blackman-windowed sinc; each polyphase branch is scaled to unit DC gain
    /// so zero-stuffing does not change the level.
    static let filter: [Double] = {
        let L = filterLength
        let center = Double(L - 1) / 2
        // A P-fold interpolator's prototype low-pass cuts at its original
        // Nyquist (1/(2P) cycles/sample of the 4x rate); a one-sided sinc has
        // cutoff a/2 for sinc(a*t), so a = 1/P.
        let a = 1.0 / Double(phases)
        var h = [Double](repeating: 0, count: L)
        for m in 0..<L {
            let t = Double(m) - center
            let arg = a * t
            let sinc = abs(arg) < 1e-9 ? 1.0 : sin(Double.pi * arg) / (Double.pi * arg)
            let w = 0.42 - 0.5 * cos(2 * Double.pi * Double(m) / Double(L - 1))
                + 0.08 * cos(4 * Double.pi * Double(m) / Double(L - 1))
            h[m] = sinc * w
        }
        // Normalize each polyphase branch to unit DC gain, not the filter as a
        // whole: a constant input must come out constant at every phase, or the
        // interpolation adds a phase-rate ripple that shows up as false peaks.
        for p in 0..<phases {
            var s = 0.0
            var k = p
            while k < L { s += h[k]; k += phases }
            guard s != 0 else { continue }
            k = p
            while k < L { h[k] /= s; k += phases }
        }
        return h
    }()

    /// True peak in dBTP for interleaved samples. -inf for silence/empty.
    static func dbtp(interleaved: [Float], channels: Int) -> Double {
        guard channels > 0, interleaved.count >= channels else { return -.infinity }
        let frames = interleaved.count / channels
        let P = phases
        // Precompute per-phase coefficient slices.
        var phaseCoeffs = [[Double]](repeating: [], count: P)
        for p in 0..<P {
            var c = [Double]()
            c.reserveCapacity(tapsPerPhase)
            for k in 0..<tapsPerPhase { c.append(filter[p + P * k]) }
            phaseCoeffs[p] = c
        }
        var peak: Double = 0
        // Only evaluate where the whole window overlaps: at the very start a
        // one-sided convolution would extrapolate the signal from zero and ring,
        // inventing a peak. The discrete sample peak below still covers those
        // few leading samples.
        let start = min(tapsPerPhase - 1, max(0, frames - 1))
        for ch in 0..<channels {
            for n in start..<frames {
                for p in 0..<P {
                    var acc = 0.0
                    let c = phaseCoeffs[p]
                    // y = sum_k c[k] * x[n-k], out-of-range taps are zero.
                    let kmax = min(tapsPerPhase, n + 1)
                    for k in 0..<kmax {
                        acc += c[k] * Double(interleaved[(n - k) * channels + ch])
                    }
                    let a = abs(acc)
                    if a > peak { peak = a }
                }
            }
        }
        // x[n] value itself is not in the polyphase grid unless p=0 includes it;
        // include the raw sample peak too so true peak >= sample peak.
        for s in interleaved {
            let a = abs(Double(s))
            if a > peak { peak = a }
        }
        return peak <= 0 ? -.infinity : 20 * log10(peak)
    }
}

/// Container writers. Input is the *final* interleaved float signal (gain and
/// dither already applied); integer depths are rounded here.
enum ExportWriter {
    static func data(interleaved: [Float], channels: Int, sampleRate: Int,
                     depth: ExportBitDepth) -> Data {
        let frames = channels > 0 ? interleaved.count / channels : 0
        switch depth {
        case .float32:
            return wav(interleaved: interleaved, frames: frames,
                       channels: channels, sampleRate: sampleRate, float: true)
        default:
            let ints = ExportPCM.quantize(interleaved, scale: depth.scale)
            return wav(interleaved: ints, channels: channels,
                       sampleRate: sampleRate, depth: depth)
        }
    }

    static func aiffData(interleaved: [Float], channels: Int, sampleRate: Int,
                         depth: ExportBitDepth) -> Data {
        let frames = channels > 0 ? interleaved.count / channels : 0
        let ints = ExportPCM.quantize(interleaved, scale: depth.scale)
        return aiff(interleaved: ints, frames: frames, channels: channels,
                    sampleRate: sampleRate, depth: depth)
    }

    // MARK: WAV (RIFF, little-endian)

    private static func wav(interleaved: [Float], frames: Int, channels: Int,
                            sampleRate: Int, float: Bool) -> Data {
        var body = [UInt8]()
        let bytesPer = 4
        let blockAlign = channels * bytesPer
        let dataSize = interleaved.count * bytesPer
        appendChunk(&body, "fmt ")
        appendU32(&body, UInt32(16))
        appendU16(&body, float ? 3 : 1)            // WAVE_FORMAT_IEEE_FLOAT / PCM
        appendU16(&body, UInt16(channels))
        appendU32(&body, UInt32(sampleRate))
        appendU32(&body, UInt32(sampleRate * blockAlign))
        appendU16(&body, UInt16(blockAlign))
        appendU16(&body, UInt16(32))
        if float {
            appendChunk(&body, "fact")
            appendU32(&body, 4)
            appendU32(&body, UInt32(frames))
        }
        appendChunk(&body, "data")
        appendU32(&body, UInt32(dataSize))
        for s in interleaved {
            let bits = s.bitPattern
            body.append(UInt8(bits & 0xFF))
            body.append(UInt8((bits >> 8) & 0xFF))
            body.append(UInt8((bits >> 16) & 0xFF))
            body.append(UInt8((bits >> 24) & 0xFF))
        }
        return wrapRIFF(body)
    }

    private static func wav(interleaved: [Int32], channels: Int,
                            sampleRate: Int, depth: ExportBitDepth) -> Data {
        var body = [UInt8]()
        let bytesPer = depth.bytesPerSample
        let blockAlign = channels * bytesPer
        let dataSize = interleaved.count * bytesPer
        appendChunk(&body, "fmt ")
        appendU32(&body, 16)
        appendU16(&body, 1)                        // WAVE_FORMAT_PCM
        appendU16(&body, UInt16(channels))
        appendU32(&body, UInt32(sampleRate))
        appendU32(&body, UInt32(sampleRate * blockAlign))
        appendU16(&body, UInt16(blockAlign))
        appendU16(&body, UInt16(depth.bits))
        appendChunk(&body, "data")
        appendU32(&body, UInt32(dataSize))
        for v in interleaved {
            let u = UInt32(bitPattern: v)
            if bytesPer == 1 {
                body.append(UInt8(u & 0xFF))
            } else if bytesPer == 2 {
                body.append(UInt8(u & 0xFF))
                body.append(UInt8((u >> 8) & 0xFF))
            } else {
                body.append(UInt8(u & 0xFF))
                body.append(UInt8((u >> 8) & 0xFF))
                body.append(UInt8((u >> 16) & 0xFF))
            }
        }
        return wrapRIFF(body)
    }

    private static func wrapRIFF(_ body: [UInt8]) -> Data {
        var out = [UInt8]()
        appendChunk(&out, "RIFF")
        appendU32(&out, UInt32(4 + body.count))
        out.append(contentsOf: "WAVE".utf8)
        out.append(contentsOf: body)
        return Data(out)
    }

    // MARK: AIFF (big-endian)

    private static func aiff(interleaved: [Int32], frames: Int, channels: Int,
                             sampleRate: Int, depth: ExportBitDepth) -> Data {
        var comm = [UInt8]()
        appendBE16(&comm, UInt16(channels))
        appendBE32(&comm, UInt32(frames))
        appendBE16(&comm, UInt16(depth.bits))
        comm.append(contentsOf: extended80(Double(sampleRate)))

        var ssnd = [UInt8]()
        appendBE32(&ssnd, 0) // offset
        appendBE32(&ssnd, 0) // block size
        let bytesPer = depth.bytesPerSample
        for v in interleaved {
            let u = UInt32(bitPattern: v)
            if bytesPer == 2 {
                ssnd.append(UInt8((u >> 8) & 0xFF))
                ssnd.append(UInt8(u & 0xFF))
            } else {
                ssnd.append(UInt8((u >> 16) & 0xFF))
                ssnd.append(UInt8((u >> 8) & 0xFF))
                ssnd.append(UInt8(u & 0xFF))
            }
        }

        var body = [UInt8]()
        body.append(contentsOf: "AIFF".utf8)
        appendChunk(&body, "COMM")
        appendBE32(&body, UInt32(comm.count))
        body.append(contentsOf: comm)
        appendChunk(&body, "SSND")
        appendBE32(&body, UInt32(ssnd.count))
        body.append(contentsOf: ssnd)
        if body.count % 2 == 1 { body.append(0) } // FORM chunks are even-sized

        var out = [UInt8]()
        appendChunk(&out, "FORM")
        appendBE32(&out, UInt32(body.count))
        out.append(contentsOf: body)
        return Data(out)
    }

    /// 80-bit IEEE extended float, the AIFF sample-rate encoding.
    static func extended80(_ value: Double) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 10)
        if value <= 0 || !value.isFinite { return bytes }
        var exponent: Int32 = 0
        let mantissa = frexp(value, &exponent) // value = m * 2^e, 0.5 <= m < 1
        let expField = UInt16(exponent + 16382)
        // mantissa is 0.5..1; the extended format keeps the leading 1 bit and a
        // 63-bit fraction, so the 64-bit mantissa is m * 2^64.
        let frac = UInt64(mantissa * 18446744073709551616.0)
        bytes[0] = UInt8((expField >> 8) & 0xFF)
        bytes[1] = UInt8(expField & 0xFF)
        for i in 0..<8 {
            bytes[2 + i] = UInt8((frac >> (56 - 8 * i)) & 0xFF)
        }
        return bytes
    }

    // MARK: byte helpers

    private static func appendChunk(_ a: inout [UInt8], _ id: String) {
        a.append(contentsOf: id.utf8)
    }
    private static func appendU16(_ a: inout [UInt8], _ v: UInt16) {
        a.append(UInt8(v & 0xFF))
        a.append(UInt8((v >> 8) & 0xFF))
    }
    private static func appendU32(_ a: inout [UInt8], _ v: UInt32) {
        a.append(UInt8(v & 0xFF))
        a.append(UInt8((v >> 8) & 0xFF))
        a.append(UInt8((v >> 16) & 0xFF))
        a.append(UInt8((v >> 24) & 0xFF))
    }
    // AIFF (FORM) writes its chunk sizes and fields big-endian.
    private static func appendBE16(_ a: inout [UInt8], _ v: UInt16) {
        a.append(UInt8((v >> 8) & 0xFF))
        a.append(UInt8(v & 0xFF))
    }
    private static func appendBE32(_ a: inout [UInt8], _ v: UInt32) {
        a.append(UInt8((v >> 24) & 0xFF))
        a.append(UInt8((v >> 16) & 0xFF))
        a.append(UInt8((v >> 8) & 0xFF))
        a.append(UInt8(v & 0xFF))
    }
}

/// What one exported file produced, including the loudness report.
struct ExportReport: Equatable {
    var sourceName: String
    var outputPath: String?
    var format: ExportFormat
    var depth: ExportBitDepth
    var frames: Int
    var sampleRate: Int
    var channels: Int
    /// Applied gain in dB (0 when none).
    var gainDB: Double
    /// Integrated gated loudness of the source material, LUFS (nil for silence).
    var loudnessLUFS: Double?
    /// Sample peak of the source material, dBFS.
    var peakDBFS: Double
    /// 4× oversampled true peak, dBTP.
    var truePeakDBTP: Double
    var ok: Bool
    var error: String?
}
