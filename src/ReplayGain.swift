import Foundation

/// How a measured track loudness is turned into playback gain (#19).
enum ReplayGainMode: String, Codable, CaseIterable {
    /// No normalization; playback volume is exactly what the user set.
    case off
    /// Each track plays at the same loudness, using its own gain.
    case track
    /// An album's tracks play at one common loudness (folder-level scan).
    case album

    var titleKey: String {
        switch self {
        case .off: return "rgOff"
        case .track: return "rgTrack"
        case .album: return "rgAlbum"
        }
    }
}

/// What one scanning pass produced for one file. Stored next to the track in a
/// `.replaygain` sidecar JSON so the original file is never rewritten.
struct ReplayGainEntry: Codable, Equatable {
    var version: Int
    /// Integrated gated loudness in LUFS; nil for (near-)silence whose blocks
    /// never clear the absolute gate.
    var trackLoudnessLUFS: Double?
    /// dB added so the track plays at ReplayGain.referenceLevel (0 for silence).
    var trackGain: Double
    /// True peak (max abs sample), 0...1.
    var trackPeak: Float
    /// Folder-level normalization, filled in after the whole folder is scanned.
    var albumGain: Double?
    var albumPeak: Float?
    var scannedAt: Date
}

/// EBU R128 / ITU-R BS.1770-4 integrated loudness plus the ReplayGain mapping.
///
/// Deliberately free of AVFoundation so the harness (tools/test_replaygain)
/// compiles the shipping math and pins it against synthetic PCM.
enum ReplayGain {
    /// Loudness, in dB, that ReplayGain normalizes to.
    static let referenceLevel = 89.0
    /// Shortest meaningful chunk of music (BS.1770-4: 400 ms).
    static let blockSeconds = 0.4
    /// Block overlap used by the reference implementation (75%).
    static let overlap = 0.75
    /// Gating: blocks quieter than an absolute -70 LUFS are not music.
    static let absoluteGate = -70.0
    /// Relative gate, 10 LU above the absolute-gated loudness (BS.1770 gating).
    static let relativeGateOffset = 10.0
    /// Calibration offset folded into every loudness reading (BS.1770-4).
    static let kOffset = -0.691

    struct Result: Equatable {
        /// Integrated gated loudness in LUFS; nil when nothing cleared the gate.
        var loudnessLUFS: Double?
        /// dB to add so the track plays at the reference level; 0 for silence.
        var gainDB: Double
        /// True peak (max abs sample), 0...1.
        var peak: Float
    }

    /// Direct-Form-I second-order section. State is private; the filter is
    /// stateless from the caller's point of view apart from its biquad taps.
    struct Biquad {
        private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        let b0, b1, b2, a1, a2: Double

        init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
            self.b0 = b0
            self.b1 = b1
            self.b2 = b2
            self.a1 = a1
            self.a2 = a2
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            return y
        }
    }

    /// RBJ high-shelf with shelf slope S = 1 (BS.1770-4's K-weighting stage 1).
    static func highShelf(f0: Double, gainDB: Double, fs: Double) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * f0 / fs
        let alpha = sin(w0) / 2 * sqrt(2.0) // sqrt((A+1/A)(1/S-1)+2) with S=1
        let cw = cos(w0)
        let s = sqrt(a)
        let b0 = a * ((a + 1) + (a - 1) * cw + 2 * s * alpha)
        let b1 = -2 * a * ((a - 1) + (a + 1) * cw)
        let b2 = a * ((a + 1) + (a - 1) * cw - 2 * s * alpha)
        let a0 = (a + 1) - (a - 1) * cw + 2 * s * alpha
        let a1 = 2 * ((a - 1) - (a + 1) * cw)
        let a2 = (a + 1) - (a - 1) * cw - 2 * s * alpha
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// RBJ high-pass (BS.1770-4's K-weighting stage 2).
    static func highPass(f0: Double, q: Double, fs: Double) -> Biquad {
        let w0 = 2 * Double.pi * f0 / fs
        let alpha = sin(w0) / (2 * q)
        let cw = cos(w0)
        let b0 = (1 + cw) / 2
        let b1 = -(1 + cw)
        let b2 = (1 + cw) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cw
        let a2 = 1 - alpha
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// The two cascaded stages of the K-weighting pre-filter, tuned to the
    /// BS.1770-4 reference EQ.
    static func kWeightFilters(fs: Double) -> (Biquad, Biquad) {
        (highShelf(f0: 1681.974450955533, gainDB: 3.999843853973347, fs: fs),
         highPass(f0: 38.13547087602444, q: 0.5003270373238773, fs: fs))
    }

    /// Mean-square energy of each `blockSeconds` block, `overlap` overlapped.
    static func blockEnergies(mono samples: [Float], sampleRate: Double) -> [Double] {
        guard sampleRate > 1, !samples.isEmpty else { return [] }
        let block = max(1, Int(blockSeconds * sampleRate))
        let hop = max(1, Int(Double(block) * (1 - overlap)))
        var energies: [Double] = []
        energies.reserveCapacity(samples.count / hop + 1)
        var start = 0
        while start + block <= samples.count {
            var acc = 0.0
            for i in start..<(start + block) {
                let v = Double(samples[i])
                acc += v * v
            }
            energies.append(acc / Double(block))
            start += hop
        }
        return energies
    }

    /// BS.1770-4 two-pass gating on block energies -> integrated LUFS.
    /// Returns nil when no block clears the absolute gate (silence/speech-gap).
    static func integratedLoudnessLUFS(energies: [Double]) -> Double? {
        guard !energies.isEmpty else { return nil }
        func lk(_ e: Double) -> Double { kOffset + 10 * log10(e + 1e-12) }
        let absoluteGated = energies.filter { lk($0) > absoluteGate }
        guard !absoluteGated.isEmpty else { return nil }
        let absolute = kOffset + 10 * log10(absoluteGated.reduce(0, +)
            / Double(absoluteGated.count))
        let relative = absolute - relativeGateOffset
        let gated = energies.filter { lk($0) > relative }
        guard !gated.isEmpty else { return nil }
        return kOffset + 10 * log10(gated.reduce(0, +) / Double(gated.count))
    }

    /// Full measurement of a mono sample array: K-weight, block energies,
    /// gating, true peak. This is the single call the scanner feeds.
    static func measure(mono samples: [Float], sampleRate: Double) -> Result {
        var peak: Float = 0
        for s in samples {
            let a = abs(s)
            if a > peak { peak = a }
        }
        var (shelf, hpf) = kWeightFilters(fs: sampleRate)
        var weighted = [Float]()
        weighted.reserveCapacity(samples.count)
        for s in samples {
            weighted.append(Float(hpf.process(shelf.process(Double(s)))))
        }
        let energies = blockEnergies(mono: weighted, sampleRate: sampleRate)
        if let lufs = integratedLoudnessLUFS(energies: energies), lufs.isFinite {
            return Result(loudnessLUFS: lufs, gainDB: referenceLevel - lufs, peak: peak)
        }
        return Result(loudnessLUFS: nil, gainDB: 0, peak: peak)
    }
}