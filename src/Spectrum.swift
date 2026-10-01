import Foundation
import Accelerate
import AVFoundation
import SwiftUI

// MARK: - Realtime capture
//
// The AVAudioEngine mixer tap runs on the audio realtime thread, so the only
// thing allowed in there is a downmix-and-copy into a preallocated ring buffer:
// no allocation, no FFT, no blocking lock. The transform runs later, on the
// main actor, well off the realtime path.

/// Lock-guarded mono ring buffer fed from the audio thread.
final class SpectrumCapture {
    /// Power of two so wrapping the write index is a mask, not a divide.
    static let capacity = 4096
    static let mask = capacity - 1
    static let fftSize = 2048
    static let binCount = fftSize / 2

    private let ring = UnsafeMutablePointer<Float>.allocate(capacity: SpectrumCapture.capacity)
    // `var` because the os_unfair_lock functions take it inout. The lock is a
    // priority-inheriting spinlock, which is the right choice on the audio
    // render thread: the reader only ever holds it for a memcpy.
    private var lock = os_unfair_lock_s()
    /// Total samples ever written. The reader needs this to tell "no audio yet"
    /// apart from "audio that happens to be zero".
    private var written: Int64 = 0
    private var rate: Double = 44100

    init() { ring.initialize(repeating: 0, count: SpectrumCapture.capacity) }
    deinit { ring.deinitialize(count: SpectrumCapture.capacity); ring.deallocate() }

    /// Realtime safe: writes only into the preallocated ring, under a
    /// priority-inheriting spinlock. Called from the AVAudioEngine render thread.
    func push(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let chans = Int(buffer.format.channelCount)
        guard frames > 0, chans > 0 else { return }

        // `floatChannelData` is one pointer per *buffer*. For a non-interleaved
        // float buffer that means one pointer per channel; for an interleaved one
        // it is a single pointer spanning frames*channels, with the channels of
        // each frame adjacent.
        let interleaved = buffer.format.isInterleaved

        os_unfair_lock_lock(&lock)
        rate = buffer.format.sampleRate
        var w = written
        if chans == 1 {
            // Mono: straight copy, no per-sample channel loop.
            data[0].withMemoryRebound(to: Float.self, capacity: frames) { src in
                for f in 0..<frames {
                    ring[Int(w) & Self.mask] = src[f]
                    w += 1
                }
            }
        } else if interleaved {
            // One contiguous run: [L0 R0 L1 R1 ...].
            for f in 0..<frames {
                var acc: Float = 0
                let base = f * chans
                for c in 0..<chans {
                    acc += data[0][base + c]
                }
                ring[Int(w) & Self.mask] = acc / Float(chans)
                w += 1
            }
        } else {
            // One contiguous plane per channel.
            for f in 0..<frames {
                var acc: Float = 0
                for c in 0..<chans {
                    acc += data[c][f]
                }
                ring[Int(w) & Self.mask] = acc / Float(chans)
                w += 1
            }
        }
        written = w
        os_unfair_lock_unlock(&lock)
    }

    /// Copies the most recent `fftSize` mono samples out. Returns the sample rate
    /// they were captured at, or nil while the buffer holds less than one
    /// transform's worth of audio.
    func latest(into out: UnsafeMutablePointer<Float>) -> Double? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard written >= Self.fftSize else { return nil }
        let start = (Int(written) - Self.fftSize) & Self.mask
        if start + Self.fftSize <= Self.capacity {
            (out).update(from: ring + start, count: Self.fftSize)
        } else {
            // Wrapped across the end of the ring.
            let first = Self.capacity - start
            (out).update(from: ring + start, count: first)
            (out + first).update(from: ring, count: Self.fftSize - first)
        }
        return rate
    }

    /// True once any buffer has arrived, so the UI can say "not wired up"
    /// (the AVPlayer engine has no mixer to tap) instead of showing silence.
    var hasSignal: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return written > 0
    }

    /// Same window as `latest(into:)`, widened to Double for the transform.
    /// The ring holds Float, so this converts rather than memcpy'ing: the two
    /// element sizes differ and a strided copy would read garbage.
    func latestDouble(into out: UnsafeMutablePointer<Double>) -> Double? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard written >= Self.fftSize else { return nil }
        let start = (Int(written) - Self.fftSize) & Self.mask
        let first = min(Self.fftSize, Self.capacity - start)
        for i in 0..<first {
            out[i] = Double(ring[start + i])
        }
        if first < Self.fftSize {
            for i in 0..<(Self.fftSize - first) {
                out[first + i] = Double(ring[i])
            }
        }
        return rate
    }

    /// Feeds a mono block directly. The mixer taps go through `push`; this
    /// exists so the test harness can drive the analyzer with synthetic tones
    /// and no audio device.
    func pushMono(_ values: UnsafePointer<Float>, count: Int, rate: Double) {
        os_unfair_lock_lock(&lock)
        self.rate = rate
        var w = written
        for i in 0..<count {
            ring[Int(w) & Self.mask] = values[i]
            w += 1
        }
        written = w
        os_unfair_lock_unlock(&lock)
    }
}

// MARK: - Transform

/// In-place iterative radix-2 Cooley-Tukey FFT over separate real/imaginary
/// planes, which is exactly the layout a real spectrum needs.
///
/// Hand-rolled rather than vDSP's, deliberately. vDSP's split-complex real FFT
/// packs its output ([Re(0), Re(N/2), Re(1), Im(1), ...]) and its `vDSP.FFT`
/// wrapper interleaves input, both of which silently halve the apparent bin
/// numbering if you get the convention wrong — a spectrum that looks plausible
/// but is wrong across the whole axis. This version's bin numbering is
/// verifiable against a naive DFT (tools/test_spectrum), which is exactly the
/// property vDSP's packing obscured.
///
/// Twiddle factors for a stage of length `len` are exp(-2*pi*i/len), recomputed
/// by repeated multiplication within each butterfly. For n = 2048 that is ~11k
/// complex multiplies per frame, which is nothing at 30 Hz.
final class Radix2FFT {
    let size: Int
    private var reversed: [Int]

    init(size: Int) {
        precondition(size > 0 && size & (size - 1) == 0,
                     "Radix2FFT needs a power-of-two size, got \(size)")
        self.size = size
        // Bit-reversal permutation, precomputed once.
        let bits = Int(log2(Double(size)))
        var table = [Int](repeating: 0, count: size)
        for i in 0..<size {
            var v = i, r = 0
            for _ in 0..<bits {
                r = (r << 1) | (v & 1)
                v >>= 1
            }
            table[i] = r
        }
        reversed = table
    }

    /// Transforms `real`/`imag` in place. Input length must equal `size`.
    func forward(real: UnsafeMutablePointer<Double>, imag: UnsafeMutablePointer<Double>) {
        // Reorder into bit-reversed index order.
        for i in 0..<size {
            let j = reversed[i]
            if j > i {
                swap(&real[i], &real[j])
                swap(&imag[i], &imag[j])
            }
        }
        var len = 2
        while len <= size {
            let ang = -2.0 * Double.pi / Double(len)
            let wr = cos(ang), wi = sin(ang)
            let half = len >> 1
            var base = 0
            while base < size {
                var cr = 1.0, ci = 0.0            // twiddle, rotated per butterfly
                for k in 0..<half {
                    let u = base + k
                    let v = u + half
                    let tr = real[v] * cr - imag[v] * ci
                    let ti = real[v] * ci + imag[v] * cr
                    real[v] = real[u] - tr
                    imag[v] = imag[u] - ti
                    real[u] += tr
                    imag[u] += ti
                    let nr = cr * wr - ci * wi
                    ci = cr * wi + ci * wr
                    cr = nr
                }
                base += len
            }
            len <<= 1
        }
    }
}

// MARK: - Analysis core

/// Result of one analysis pass, in display units.
struct SpectrumFrame {
    /// Per-band level, 0...1.
    var bands: [Float]
    /// The dB window these levels were mapped from, so the readout and the bars
    /// cannot drift apart.
    var floorDb: Double
    var span: Double

    /// Convert a 0...1 level back to dBFS.
    func decibelsAt(_ level: Float) -> Float {
        Float(floorDb + Double(level) * span)
    }
}

/// Windowing, transform and log band mapping. Not actor-isolated and with no
/// SwiftUI or AVFoundation dependencies beyond the capture buffer, so
/// tools/test_spectrum can compile and exercise the real code.
final class SpectrumCore {
    static let n = SpectrumCapture.fftSize
    static let binCount = SpectrumCapture.binCount
    static let bandCount = 64

    /// Band edges. Below ~30 Hz a spectrum display is all inaudible rumble; 16 kHz
    /// keeps the top bands meaningful on a 48 kHz device instead of dedicating a
    /// quarter of the display to bins that only exist when upsampled.
    static let lowHz: Double = 30
    static let highHz: Double = 16_000

    /// dB display range. The -72 floor keeps silence flat without letting dither
    /// noise wiggle the display. The ceiling is true 0 dBFS rather than a padded
    /// value: anything lower pins ordinary material at full scale, since a 0.5
    /// amplitude tone already sits at -6 dBFS.
    static let floorDb: Double = -72
    static let ceilingDb: Double = 0

    /// Latest window of mono samples, refreshed from the ring before each pass.
    let samples: UnsafeMutablePointer<Double>
    private let window: UnsafeMutablePointer<Double>
    private let fftRe: UnsafeMutablePointer<Double>
    private let fftIm: UnsafeMutablePointer<Double>
    private let magnitudes: UnsafeMutablePointer<Double>
    private let fft: Radix2FFT

    /// Bin index range per band, plus the bin width in Hz. Rebuilt whenever the
    /// device rate changes, since the tap's format is only known once the engine
    /// runs.
    private var binEdges: [(lo: Int, hi: Int)] = []
    private var binHz: Double = 0

    init() {
        samples = .allocate(capacity: Self.n)
        window = .allocate(capacity: Self.n)
        fftRe = .allocate(capacity: Self.n)
        fftIm = .allocate(capacity: Self.n)
        magnitudes = .allocate(capacity: Self.binCount)
        for p in [samples, window, fftRe, fftIm] {
            p.initialize(repeating: 0, count: Self.n)
        }
        magnitudes.initialize(repeating: 0, count: Self.binCount)
        // Hann window, precomputed once. Symmetric form, matching the reference
        // harness in tools/test_spectrum.
        let d = Double(Self.n - 1)
        for i in 0..<Self.n {
            window[i] = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / d)
        }
        fft = Radix2FFT(size: Self.n)
    }

    deinit {
        for p in [samples, window, fftRe, fftIm] {
            p.deinitialize(count: Self.n); p.deallocate()
        }
        magnitudes.deinitialize(count: Self.binCount); magnitudes.deallocate()
    }

    /// Raw magnitudes for the latest `samples` window, scaled so that a
    /// full-scale sine reads 1.0. Exposed so the harness can assert on exact
    /// bin numbers.
    ///
    /// A cosine of amplitude A windowed by Hann has peak bin magnitude A*n/4: the
    /// window's coherent gain halves it and the cosine itself is half its peak
    /// amplitude at the bin. Scaling by 4/n therefore puts a full-scale tone at
    /// 1.0, which is what makes the dB mapping below mean anything.
    func rawMagnitudes() -> [Double] {
        for i in 0..<Self.n {
            fftRe[i] = samples[i] * window[i]
            fftIm[i] = 0
        }
        fft.forward(real: fftRe, imag: fftIm)
        // Bin k of an n-point transform at rate R sits at k * R / n Hz, and a real
        // input's bins above n/2 mirror lower ones, so the first half is the whole
        // spectrum.
        let scale = 4.0 / Double(Self.n)
        var out = [Double](repeating: 0, count: Self.binCount)
        for k in 0..<Self.binCount {
            let re = fftRe[k] * scale, im = fftIm[k] * scale
            out[k] = (re * re + im * im).squareRoot()
        }
        return out
    }

    /// Window + transform + log band mapping over the current `samples`.
    func analyse(rate: Double) -> SpectrumFrame {
        rebuildBandMapIfNeeded(rate: rate)
        let mags = rawMagnitudes()
        for k in 0..<Self.binCount { magnitudes[k] = mags[k] }

        let span = Self.ceilingDb - Self.floorDb
        var bands = [Float](repeating: 0, count: Self.bandCount)
        for band in 0..<Self.bandCount {
            let edge = binEdges[band]
            // Max within the band, not mean: a narrow tone inside a wide band
            // would be averaged almost to nothing.
            var peak = 0.0
            if edge.hi >= edge.lo {
                for k in edge.lo...edge.hi where magnitudes[k] > peak {
                    peak = magnitudes[k]
                }
            }
            let db = 20 * log10(max(peak, 1e-9))
            bands[band] = Float(min(1, max(0, (db - Self.floorDb) / span)))
        }
        return SpectrumFrame(bands: bands, floorDb: Self.floorDb, span: span)
    }

    /// Centre frequency of a band in Hz, for the axis labels. Nil until the
    /// device rate is known.
    func bandFrequency(_ band: Int) -> Double? {
        guard binEdges.count == Self.bandCount, band >= 0, band < Self.bandCount else { return nil }
        let e = binEdges[band]
        return (Double(e.lo + e.hi) / 2) * binHz
    }

    private func rebuildBandMapIfNeeded(rate: Double) {
        let hz = rate / Double(Self.n)
        guard abs(hz - binHz) > 1e-9 else { return }
        binHz = hz
        let last = Self.binCount - 1
        var edges: [(lo: Int, hi: Int)] = []
        edges.reserveCapacity(Self.bandCount)
        let ratio = Self.highHz / Self.lowHz
        for band in 0..<Self.bandCount {
            // Log spacing: tight at the bottom where pitch lives, wide up top.
            let f0 = Self.lowHz * pow(ratio, Double(band) / Double(Self.bandCount))
            let f1 = Self.lowHz * pow(ratio, Double(band + 1) / Double(Self.bandCount))
            let lo = min(max(0, Int(f0 / binHz)), last)
            var hi = min(max(0, Int(f1 / binHz) - 1), last)
            if hi < lo { hi = lo }
            edges.append((lo, hi))
        }
        binEdges = edges
    }
}

// MARK: - Analysis

/// Log-spaced spectrum analysis feeding the Effects tab (#16).
///
/// Bars are `0...1` and pre-smoothed for display. The transform only runs while
/// `setActive(true)`, so a player who never opens the drawer pays nothing.
/// PlayerState's engine taps and the Effects tab both need this instance, and
/// the tap callbacks are installed from the engine-start paths, which have no
/// other route to the store — hence a singleton.
@MainActor
final class SpectrumAnalyzer: ObservableObject {
    static let shared = SpectrumAnalyzer()
    static var bandCount: Int { SpectrumCore.bandCount }

    /// Ring buffer the mixer taps feed. A module-level constant rather than a
    /// property: the tap closure is invoked from the audio render thread, which
    /// cannot touch main-actor state, and this type is realtime-safe by
    /// construction (a downmix-and-copy under a spinlock, nothing else).
    nonisolated static let capture = SpectrumCapture()

    /// 30 Hz is smooth for bars and leaves the CPU alone.
    private static let frameInterval = 1.0 / 30.0
    private var timer: Timer?

    /// Windowing, transform and band mapping. Kept out of the @MainActor type so
    /// the test harness can run the exact production code without a run loop.
    private let core = SpectrumCore()

    /// Bars are pre-smoothed here rather than in the core, so a fresh core gives
    /// raw magnitudes and the smoothing stays a display concern.
    @Published private(set) var bars: [Float] = Array(repeating: 0, count: bandCount)
    @Published private(set) var peaks: [Float] = Array(repeating: 0, count: bandCount)
    @Published private(set) var peakDecibels: Float?
    @Published private(set) var hasSignal = false

    /// Centre frequency of a band in Hz, for the axis labels. Nil until the
    /// device rate is known.
    func bandFrequency(_ band: Int) -> Double? { core.bandFrequency(band) }

    /// Gates the FFT and the timer. Driven by the Effects tab's onAppear /
    /// onDisappear, so a player who never opens the drawer pays nothing.
    func setActive(_ active: Bool) {
        if active == (timer != nil) { return }
        if active {
            let t = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.step() }
            }
            t.tolerance = Self.frameInterval / 3
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            timer?.invalidate()
            timer = nil
            bars = Array(repeating: 0, count: Self.bandCount)
            peaks = Array(repeating: 0, count: Self.bandCount)
            peakDecibels = nil
            hasSignal = false
        }
    }

    /// Taps an engine's mixer. Call once per engine as it starts; the tap only
    /// ever feeds the ring buffer, so it is cheap enough to leave installed.
    nonisolated func attach(to engine: AVAudioEngine) {
        let capture = Self.capture
        // `format: nil` uses the mixer's own output format, i.e. exactly the
        // rate and channel count the user is hearing.
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            capture.push(buffer)
        }
    }

    private func step() {
        guard let rate = Self.capture.latestDouble(into: core.samples) else {
            // Nothing buffered yet: fall back to resting bars, and say so when
            // the engine never delivered audio (AVPlayer has no mixer to tap).
            hasSignal = Self.capture.hasSignal
            decay()
            return
        }
        hasSignal = true
        let raw = core.analyse(rate: rate)

        var loudest: Float = 0
        for band in 0..<Self.bandCount {
            let norm = raw.bands[band]
            // Fast attack, slow release: bars snap up and fall away gently.
            let previous = bars[band]
            bars[band] = norm > previous ? norm : previous * 0.82 + norm * 0.18
            // Peak marker falls slowly so transients stay readable.
            peaks[band] = max(bars[band], peaks[band] - 0.012)
            if norm > loudest { loudest = norm }
        }
        peakDecibels = loudest > 0.002 ? raw.decibelsAt(loudest) : nil
    }

    private func decay() {
        for i in 0..<Self.bandCount {
            bars[i] *= 0.7
            peaks[i] *= 0.9
        }
        peakDecibels = nil
    }
}

// MARK: - Drawing

/// Bar-graph rendering of the analysis. Canvas rather than a stack of SwiftUI
/// shapes: 64 bars with a peak cap each is well past what a view hierarchy is
/// happy to redraw at 30 Hz.
struct SpectrumBars: View {
    @ObservedObject var analyzer: SpectrumAnalyzer
    var accent: Color
    var secondary: Color

    var body: some View {
        GeometryReader { geo in
            let bars = analyzer.bars
            let peaks = analyzer.peaks
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                guard !bars.isEmpty, size.width > 0, size.height > 0 else { return }
                let gap: CGFloat = 1
                let slot = size.width / CGFloat(bars.count)
                let barWidth = max(1, slot - gap)
                let floor = size.height

                var barsPath = Path()
                var capsPath = Path()
                var dotsPath = Path()

                for (i, value) in bars.enumerated() {
                    let v = min(1, max(0, value))
                    let x = CGFloat(i) * slot + gap / 2
                    if v > 0 {
                        let h = max(1, CGFloat(v) * (floor - 2))
                        barsPath.addRoundedRect(
                            in: CGRect(x: x, y: floor - h, width: barWidth, height: h),
                            cornerSize: CGSize(width: min(1.5, barWidth / 2), height: 1.5))
                    }
                    let p = min(1, max(0, peaks[i]))
                    if p > 0.004 {
                        let y = floor - CGFloat(p) * (floor - 2)
                        capsPath.addRect(CGRect(x: x, y: y - 1, width: barWidth, height: 2))
                        if barWidth >= 4 {
                            dotsPath.addEllipse(
                                in: CGRect(x: x + barWidth / 2 - 1, y: y - 1,
                                           width: 2, height: 2))
                        }
                    }
                }
                context.fill(barsPath, with: .linearGradient(
                    Gradient(colors: [accent, secondary]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: floor)))
                context.fill(capsPath, with: .color(.primary.opacity(0.5)))
                context.fill(dotsPath, with: .color(.primary.opacity(0.85)))
            }
            .background(alignment: .bottom) {
                // A hairline floor, so a silent display still reads as a display.
                Rectangle().fill(.primary.opacity(0.15)).frame(height: 1)
            }
        }
    }
}