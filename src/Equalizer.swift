import Foundation
import AVFoundation
import SwiftUI

/// Handles an inclusive biquad coefficient for a gain in decibels, on top of
/// the RBJ peaking-filter formulae, so the harness can check the maths that the
/// AU-level bands are configured to implement.
/// A named 10-slot curve users can load whole; the sliders stay live afterwards.
struct EqualizerPreset {
    let id: String
    let gains: [Double]
}

enum EqualizerCore {
    static let bandCount = 10
    /// The classic hardware ten-slopers: one-octave spacing, 31 Hz .. 16 kHz.
    static let centers: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let minGain: Double = -12
    static let maxGain: Double = 12

    /// Popular curves derived from the classic bog-standard graphic-EQ banks
    /// (Rock/Pop/Classical/Jazz/Electronic as played by every player app) plus
    /// the three single-purpose boosts people actually phone the EQ for. All
    /// gains stay inside ±12 dB and gentle enough that the summed curve cannot
    /// clip the mixer.
    static let presets: [EqualizerPreset] = [
        EqualizerPreset(id: "flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        EqualizerPreset(id: "pop", gains: [1.0, 1.5, 2.0, 1.5, 1.0, 2.0, 3.0, 2.5, 2.0, 1.5]),
        EqualizerPreset(id: "rock", gains: [4.0, 3.0, -2.0, -4.0, -1.0, 2.0, 4.0, 5.0, 4.0, 3.0]),
        EqualizerPreset(id: "classical", gains: [-2.0, -1.0, 0.5, 1.0, 1.0, 1.5, 2.0, 2.0, 2.5, 2.0]),
        EqualizerPreset(id: "jazz", gains: [-1.0, 1.0, 2.0, 2.5, 2.0, 1.5, 1.0, 0.5, 0.0, -1.0]),
        EqualizerPreset(id: "electronic", gains: [5.0, 4.5, 1.0, -1.5, -3.0, -1.5, 1.0, 3.0, 4.0, 4.5]),
        EqualizerPreset(id: "hiphop", gains: [3.0, 4.0, 1.5, -1.0, -2.0, -2.0, -1.0, 1.0, 2.5, 3.0]),
        EqualizerPreset(id: "bassboost", gains: [5.0, 4.0, 2.0, 1.0, 0, 0, 0, 0, 0, 0]),
        EqualizerPreset(id: "vocalboost", gains: [-3.0, -2.0, -1.0, 0.0, 2.0, 3.5, 4.0, 3.0, 1.5, 1.0]),
        EqualizerPreset(id: "trebleboost", gains: [0, 0, 0, 0, 0, 0.5, 1.5, 3.0, 4.5, 5.0]),
    ]

    static func preset(id: String) -> EqualizerPreset? {
        presets.first { $0.id == id }
    }

    static func clampGain(_ db: Double) -> Double {
        min(maxGain, max(minGain, db))
    }

    /// Peaking biquad (RBJ cookbook), sample-rate independent of audio; the
    /// coefficients are returned for the filter that peaks `db` at the center
    /// frequency with the given quality factor.
    /// Returns nil when Q is not finite/positive.
    static func peakingCoefficients(sampleRate: Double, center: Double,
                                    q: Double, db: Double) -> [Double]? {
        guard q.isFinite, q > 0, center.isFinite, center > 0,
              sampleRate.isFinite, sampleRate > 0 else { return nil }
        let a2 = pow(10.0, clampGain(db) / 40.0)
        let omega = 2.0 * Double.pi * center / sampleRate
        let alpha = sin(omega) / (2.0 * q)
        let cs = cos(omega)
        let b0 = 1 + alpha * a2
        let b1 = -2 * cs
        let b2 = 1 - alpha * a2
        let a0 = 1 + alpha / a2
        let a1 = -2 * cs
        let a2a = 1 - alpha / a2
        let b0n = b0 / a0
        let b1n = b1 / a0
        let b2n = b2 / a0
        let a1n = a1 / a0
        let a2n = a2a / a0
        return [b0n, b1n, b2n, a1n, a2n]
    }

    /// Linear magnitude response (1.0 = no change) of the peaking filter at a
    /// given frequency, evaluated on the unit circle in the standard way.
    static func responseAt(sampleRate: Double, center: Double, q: Double,
                           db: Double, frequency: Double) -> Double {
        guard let c = peakingCoefficients(sampleRate: sampleRate, center: center,
                                          q: q, db: db) else { return 1 }
        let b0 = c[0], b1 = c[1], b2 = c[2], a1 = c[3], a2c = c[4]
        let w = 2.0 * Double.pi * frequency / sampleRate
        let cw = cos(w), cw2 = cos(2 * w)
        let sw = sin(w), sw2 = sin(2 * w)
        let Nr = b0 + b1 * cw + b2 * cw2
        let Ni = -(b1 * sw + b2 * sw2)
        let Dr = 1 + a1 * cw + a2c * cw2
        let Di = -(a1 * sw + a2c * sw2)
        let magSq = (Nr * Nr + Ni * Ni) / (Dr * Dr + Di * Di)
        return sqroot(magSq)
    }
}

private extension Double {
    var finiteOrZero: Double { isFinite ? self : 0 }
}

private func sqroot(_ x: Double) -> Double {
    x < 0 ? 0 : x.squareRoot()
}

/// 10-band equalizer state for the Effects tab. The DSP itself is a single
/// `AVAudioUnitEQ` inserted between each in-app engine's main mixer and its
/// output node, so native/embedded/midi-E playback all pass through it. The
/// AVPlayer fallback engine and the AVMIDIPlayer path cannot host an AU insert
/// and are documented as staying flat.
@MainActor
final class Equalizer: ObservableObject {
    static let shared = Equalizer()

    @Published private(set) var isActive: Bool {
        didSet { persist(); refreshLive() }
    }
    @Published private(set) var gains: [Double] {
        didSet { persist(); refreshLive() }
    }
    /// The preset currently loaded, or nil once the user nudges a slider (a
    /// manual curve is no longer any one preset).
    @Published private(set) var selectedPreset: String? {
        didSet { persist() }
    }

    /// Every AVAudioUnitEQ currently inserted into a live engine.
    private var installed: [AVAudioUnitEQ] = []

    private init() {
        isActive = UserDefaults.standard.bool(forKey: "ac_eq_active")
        let stored = UserDefaults.standard.string(forKey: "ac_eq_gains")?
            .split(separator: ",").compactMap { Double($0) } ?? []
        if stored.count == EqualizerCore.bandCount {
            gains = stored
        } else {
            gains = Array(repeating: 0, count: EqualizerCore.bandCount)
        }
        let presetID = UserDefaults.standard.string(forKey: "ac_eq_preset")
        if let preset = presetID.flatMap(EqualizerCore.preset(id:)) {
            gains = preset.gains
            selectedPreset = presetID
        } else {
            selectedPreset = nil
        }
    }

    // MARK: - Public API

    func setActive(_ on: Bool) {
        guard isActive != on else { return }
        isActive = on
    }

    /// Loads a named curve and marks it as the selected preset. The sliders are
    /// still live afterwards; any manual move clears the selection.
    func applyPreset(id: String) {
        guard let preset = EqualizerCore.preset(id: id) else { return }
        gains = preset.gains
        selectedPreset = id
    }

    /// Sliders write through here (array slots cannot trigger @didSet on their own).
    func setGain(_ db: Double, at index: Int) {
        guard gains.indices.contains(index) else { return }
        let clamped = EqualizerCore.clampGain(db)
        guard abs(gains[index] - clamped) > 0.0001 else { return }
        var next = gains
        next[index] = clamped
        gains = next
        selectedPreset = nil
    }

    /// A value binding for a single slider.
    func bindingFor(index: Int) -> Binding<Double> {
        Binding(get: { [weak self] in self?.gains[index] ?? 0 },
                set: { [weak self] v in self?.setGain(v, at: index) })
    }

    func resetAll() {
        gains = Array(repeating: 0, count: EqualizerCore.bandCount)
        selectedPreset = nil
    }

    /// Adds the EQ node between the engine's main mixer and its output node.
    ///
    /// The node is always inserted so that flipping the switch mid-track has an
    /// immediate effect; on/off is `AVAudioUnitEQ.bypass`, applied live in
    /// `apply(to:)` rather than by tearing the graph down.
    @discardableResult
    func install(on engine: AVAudioEngine) -> AVAudioUnitEQ {
        let eq = makeEQ()
        engine.attach(eq)
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.disconnectNodeOutput(engine.mainMixerNode)
        engine.connect(engine.mainMixerNode, to: eq, format: format)
        engine.connect(eq, to: engine.outputNode, format: format)
        installed.append(eq)
        return eq
    }

    func uninstall(_ node: AVAudioUnitEQ) {
        installed.removeAll { $0 === node }
    }

    // MARK: - Internals

    private func makeEQ() -> AVAudioUnitEQ {
        let eq = AVAudioUnitEQ(numberOfBands: EqualizerCore.bandCount)
        apply(to: eq)
        return eq
    }

    private func apply(to eq: AVAudioUnitEQ) {
        eq.bypass = !isActive
        eq.globalGain = 0
        for i in 0..<min(EqualizerCore.bandCount, eq.bands.count) {
            let band = eq.bands[i]
            band.filterType = .parametric
            band.frequency = EqualizerCore.centers[i]
            band.bandwidth = 1.0
            band.gain = Float(gains[i])
        }
    }

    private func refreshLive() {
        for eq in installed { apply(to: eq) }
    }

    private func persist() {
        UserDefaults.standard.set(isActive, forKey: "ac_eq_active")
        UserDefaults.standard.set(gains.map { String($0) }.joined(separator: ","),
                                  forKey: "ac_eq_gains")
        UserDefaults.standard.set(selectedPreset, forKey: "ac_eq_preset")
    }
}