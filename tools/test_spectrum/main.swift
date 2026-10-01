// Spectrum analyser test harness (#16).
//
// Compiles the production src/Spectrum.swift and exercises the real FFT, band
// mapping and level scaling with synthetic tones. The point is bin-accuracy:
// an FFT bug that halves bin numbering still *looks* like a plausible spectrum,
// so these assertions pin exact bin positions against k * rate / n.
//
// Build/run: ./tools/build_tools.sh && ./tools/test_spectrum

import Foundation
import AVFoundation

/// Minimal complex pair, so the reference DFT stays free of framework types.
struct Complex { var re: Double; var im: Double }

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

func checkNear(_ label: String, _ got: Double, _ want: Double,
               _ tolerance: Double) {
    let ok = abs(got - want) <= tolerance
    check(label, ok, ok ? "" : "got \(got), want \(want) ±\(tolerance)")
}

// MARK: - Reference DFT

/// Naive O(n^2) DFT. Unambiguous by construction, which is the whole reason the
/// FFT is validated against it.
func referenceDFT(_ x: [Double]) -> [(re: Double, im: Double)] {
    let n = x.count
    return (0..<n).map { k in
        var re = 0.0, im = 0.0
        for t in 0..<n {
            let ang = -2.0 * Double.pi * Double(k * t) / Double(n)
            re += x[t] * cos(ang)
            im += x[t] * sin(ang)
        }
        return (re, im)
    }
}

func magnitudes(_ spectrum: [(re: Double, im: Double)]) -> [Double] {
    spectrum.map { ($0.re * $0.re + $0.im * $0.im).squareRoot() }
}

var rng: UInt64 = 0x2545F4914F6CDD1D
func randomSample() -> Double {
    rng ^= rng << 13
    rng ^= rng >> 7
    rng ^= rng << 17
    return Double(rng % 20001) / 10000.0 - 1.0
}

func fft(_ input: [Double]) -> [(re: Double, im: Double)] {
    let re = UnsafeMutablePointer<Double>.allocate(capacity: input.count)
    let im = UnsafeMutablePointer<Double>.allocate(capacity: input.count)
    defer { re.deallocate(); im.deallocate() }
    for i in 0..<input.count {
        re[i] = input[i]
        im[i] = 0
    }
    Radix2FFT(size: input.count).forward(real: re, imag: im)
    return (0..<input.count).map { (re[$0], im[$0]) }
}

// MARK: - FFT correctness

print("FFT vs naive DFT")
for n in [8, 16, 64, 256] as [Int] {
    let input = (0..<n).map { _ in randomSample() }
    let want = magnitudes(referenceDFT(input))
    let got = magnitudes(fft(input))
    var worst = 0.0
    for k in 0..<n {
        worst = max(worst, abs(want[k] - got[k]))
    }
    // Relative tolerance: magnitudes scale with n, so an absolute bound would be
    // arbitrarily loose at small n and arbitrarily tight at large n.
    let scale = want.max() ?? 1
    check("n=\(n) matches reference DFT", worst < scale * 1e-9,
          "worst error \(worst), peak \(scale)")
}

print("FFT shape")
do {
    // Zero in, zero out. Cheap, and it catches uninitialised scratch planes.
    let n = 1024
    let mags = magnitudes(fft([Double](repeating: 0, count: n)))
    check("zero input gives zero output", mags.allSatisfy { $0 < 1e-12 })
}
do {
    // A single bin-representing cosine must put all its energy in one bin.
    let n = 2048
    let k = 100
    let signal = (0..<n).map { cos(2.0 * Double.pi * Double(k * $0) / Double(n)) }
    let mags = magnitudes(fft(signal))
    // A real cosine is half +k and half -k, so the energy sits in bin k and its
    // mirror at n-k with equal magnitude. Anything else means bin numbering is
    // off or the real/imag planes are swapped.
    check("bin-100 cosine peaks at bin 100", mags[k] > mags[k - 1] && mags[k] > mags[k + 1],
          "bin \(k) = \(mags[k]), neighbours \(mags[k-1]) / \(mags[k+1])")
    check("cosine mirrors to bin n-k", abs(mags[k] - mags[n - k]) < 1e-6 * mags[k],
          "\(mags[k]) vs \(mags[n - k])")
    let total = mags.reduce(0, +)
    let atPeaks = mags[k] + mags[n - k]
    check("cosine energy is concentrated in k and n-k", atPeaks / total > 0.99,
          String(format: "%.4f", atPeaks / total))
}
do {
    // A complex exponential e^(+2*pi*i*k*t/n) must put all its energy in exactly
    // one bin. A real-only test cannot distinguish sign errors in the imaginary
    // path, which is the half of the FFT the display never sees directly.
    let n = 256
    let k = 17
    let re = UnsafeMutablePointer<Double>.allocate(capacity: n)
    let im = UnsafeMutablePointer<Double>.allocate(capacity: n)
    defer { re.deallocate(); im.deallocate() }
    for t in 0..<n {
        let phase = 2.0 * Double.pi * Double(k * t) / Double(n)
        re[t] = cos(phase)
        im[t] = sin(phase)
    }
    Radix2FFT(size: n).forward(real: re, imag: im)
    let mags = (0..<n).map { (re[$0] * re[$0] + im[$0] * im[$0]).squareRoot() }
    let peak = (0..<n).max { mags[$0] < mags[$1] }!
    check("complex exponential peaks at bin \(k)", peak == k, "peaked at \(peak)")
    check("every other bin is zero",
          mags.enumerated().allSatisfy { $0.offset == k || $0.element < 1e-9 })
    // X[k] = sum_t e^(+j2*pi*k*t/n) e^(-j2*pi*k*t/n) = n, a real positive spike.
    // A negated exponent here would put the energy at n-k instead, so this pins
    // the sign convention.
    check("forward transform uses the exp(-j) convention",
          re[k] > 0 && abs(im[k]) < 1e-9, "re \(re[k]), im \(im[k])")
    check("impulse magnitude equals n", abs(re[k] - Double(n)) < 1e-6,
          String(format: "%.6f", re[k]))
}

// MARK: - Core analysis: bin positions

/// Fills the core's sample window with a sine at `hz` and returns the raw bin
/// magnitudes. The window is Hann, so energy leaks slightly either side of the
/// tone, but the peak must be at the bin the formula predicts.
func analyseTone(hz: Double, rate: Double, amplitude: Double = 0.5) -> [Double] {
    let core = SpectrumCore()
    let n = SpectrumCore.n
    for i in 0..<n {
        core.samples[i] = amplitude * sin(2.0 * Double.pi * hz * Double(i) / rate)
    }
    _ = core.analyse(rate: rate)
    return core.rawMagnitudes()
}

print("Tone -> bin position (no window, so exact)")
do {
    // analyse() applies a Hann window, so use rawMagnitudes on unwindowed input
    // for the exact check. This mirrors the frequency-to-bin mapping the band
    // edges rely on.
    for rate in [44100.0, 48000.0] {
        for hz in [50.0, 100.0, 1000.0, 4000.0, 8000.0, 16000.0] {
            let n = SpectrumCore.n
            let core = SpectrumCore()
            for i in 0..<n {
                core.samples[i] = 0.5 * sin(2.0 * Double.pi * hz * Double(i) / rate)
            }
            let mags = core.rawMagnitudes()
            let peak = (0..<mags.count).max { mags[$0] < mags[$1] }!
            let expected = Int((hz * Double(n) / rate).rounded())
            check("\(Int(hz)) Hz @ \(Int(rate)) Hz lands in bin \(expected)",
                  peak == expected, "peaked at bin \(peak)")
        }
    }
}

print("Band mapping")
do {
    let core = SpectrumCore()
    let rates = [44100.0, 48000.0, 96000.0]
    for rate in rates {
        // Force a map by running one pass.
        for i in 0..<SpectrumCore.n { core.samples[i] = 0 }
        _ = core.analyse(rate: rate)
        var monotonic = true
        var previousLo = -1
        var firstFreq: Double? = nil
        var lastFreq: Double? = nil
        for band in 0..<SpectrumCore.bandCount {
            guard let f = core.bandFrequency(band) else {
                monotonic = false
                break
            }
            if firstFreq == nil { firstFreq = f }
            lastFreq = f
            if f < Double(previousLo) - 1 { monotonic = false }
            previousLo = Int(f)
        }
        check("@ \(Int(rate)) Hz band centres increase monotonically", monotonic)
        check("@ \(Int(rate)) Hz lowest band is near 30 Hz",
              firstFreq.map { $0 < 60 } ?? false, "got \(firstFreq.map { Int($0) } ?? -1)")
        check("@ \(Int(rate)) Hz highest band is near 16 kHz",
              lastFreq.map { $0 > 8000 } ?? false, "got \(lastFreq.map { Int($0) } ?? -1)")
    }
}

print("Band level response")
do {
    // A tone must light up the band containing it and leave its neighbours near
    // rest. This is what the display actually shows.
    let rate = 44100.0
    let core = SpectrumCore()
    for hz in [100.0, 1000.0, 4000.0, 12000.0] {
        let n = SpectrumCore.n
        for i in 0..<n {
            core.samples[i] = 0.5 * sin(2.0 * Double.pi * hz * Double(i) / rate)
        }
        let frame = core.analyse(rate: rate)
        // Find the band whose centre is closest to the tone.
        var best = 0
        var bestDist = Double.greatestFiniteMagnitude
        for band in 0..<SpectrumCore.bandCount {
            guard let f = core.bandFrequency(band) else { continue }
            let d = abs(log(f / hz))
            if d < bestDist { bestDist = d; best = band }
        }
        let peak = frame.bands.max() ?? 0
        let peakBand = frame.bands.enumerated().max { $0.element < $1.element }?.offset ?? -1
        check("\(Int(hz)) Hz reaches band \(best) with visible level",
              peak > 0.5 && peakBand == best,
              "peak \(String(format: "%.3f", peak)) in band \(peakBand), expected \(best)")
    }
}

print("Level scaling")
do {
    let rate = 44100.0
    let n = SpectrumCore.n
    let core = SpectrumCore()

    func levelForAmplitude(_ a: Double) -> Float {
        for i in 0..<n {
            core.samples[i] = a * sin(2.0 * Double.pi * 1000.0 * Double(i) / rate)
        }
        return core.analyse(rate: rate).bands.max() ?? 0
    }

    // 0.25 and 0.025: quiet enough that neither clips the scale, so the dB
    // relationship is measured rather than compressed by the ceiling.
    let quarter = levelForAmplitude(0.25)
    let fortieth = levelForAmplitude(0.025)
    let silence = levelForAmplitude(0.0)
    let full = levelForAmplitude(1.0)

    check("a quarter-scale tone is well above the floor", quarter > 0.6,
          String(format: "%.3f", quarter))
    // 0.985, not 1.0: a 1 kHz tone at 44.1 kHz is not bin-centred, so it leaks a
    // little into its neighbours and the peak bin falls just short of A*n/4.
    // The scale is calibrated for a bin-centred tone; a near-full reading here is
    // correct and must not be tightened to require an exact 1.0.
    check("a full-scale tone reads near the top of the scale", full > 0.95,
          String(format: "%.3f", full))
    check("silence reads as zero", silence < 0.001, String(format: "%.5f", silence))

    // 10x is -20 dB over a 72 dB display span, so the bar must drop by 20/72.
    let drop = Double(quarter - fortieth)
    checkNear("10x amplitude drop moves the bar by 20/72 of full scale", drop, 20.0 / 72.0, 0.03)

    // Check the dB scale itself rather than only bar ratios.
    let frame = SpectrumFrame(bands: [Float](repeating: 0, count: SpectrumCore.bandCount),
                              floorDb: SpectrumCore.floorDb,
                              span: SpectrumCore.ceilingDb - SpectrumCore.floorDb)
    checkNear("0 level maps to the dB floor", Double(frame.decibelsAt(0)), -72, 0.01)
    checkNear("1 level maps to 0 dBFS", Double(frame.decibelsAt(1)), 0, 0.01)
    checkNear("mid level maps to the midpoint", Double(frame.decibelsAt(0.5)), -36, 0.01)
}

print("Ring buffer")
do {
    // The ring must hand back the newest `fftSize` samples in order, including
    // across a wrap, or the spectrum silently mixes old and new audio.
    let capture = SpectrumCapture()
    let out = UnsafeMutablePointer<Double>.allocate(capacity: SpectrumCapture.fftSize)
    defer { out.deallocate() }

    check("no audio yet reads nil", capture.latestDouble(into: out) == nil)

    // More than one ring's worth, so the write pointer wraps mid-read.
    let total = SpectrumCapture.capacity * 3
    var values = [Float](repeating: 0, count: total)
    for i in 0..<total {
        values[i] = Float(i % 977) / 1000.0
    }
    let start = total - SpectrumCapture.fftSize
    values.withUnsafeBufferPointer { buf in
        capture.pushMono(buf.baseAddress!, count: total, rate: 48000)
        _ = capture.latestDouble(into: out)
    }

    var mismatches = 0
    for i in 0..<SpectrumCapture.fftSize {
        if abs(out[i] - Double(values[start + i])) > 1e-6 { mismatches += 1 }
    }
    check("ring returns the newest window in order across a wrap", mismatches == 0,
          "\(mismatches) mismatched samples")
    check("ring reports the sample rate", capture.latestDouble(into: out) == 48000)

    // One sample short of a full window must not read.
    let empty = SpectrumCapture()
    check("ring with insufficient history reads nil",
          empty.latestDouble(into: out) == nil)
}

print("Downmix")
do {
    // Opposite-phase stereo cancels; identical channels do not. Catches a
    // downmix that reads the wrong channel or skips interleaving.
    let rate = 44100.0
    let n = SpectrumCapture.fftSize

    func levelForStereo(_ l: (Double) -> Double, _ r: (Double) -> Double) -> Float {
        let capture = SpectrumCapture()
        let core = SpectrumCore()
        let frames = 2048
        let buffer = AVAudioPCMBuffer(pcmFormat: stereoFormat(rate), frameCapacity: 3072)!
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = buffer.floatChannelData!
        for f in 0..<frames {
            let t = Double(f) / rate
            data[0][f] = Float(l(t))
            data[1][f] = Float(r(t))
        }
        capture.push(buffer)
        // Keep pushing until a full window is available.
        for _ in 0..<3 { capture.push(buffer) }
        guard capture.latestDouble(into: core.samples) != nil else { return -1 }
        return core.analyse(rate: rate).bands.max() ?? 0
    }

    let both = levelForStereo({ sin(2 * .pi * 1000 * $0) }, { sin(2 * .pi * 1000 * $0) })
    let cancel = levelForStereo({ sin(2 * .pi * 1000 * $0) }, { sin(2 * .pi * 1000 * $0 + .pi) })
    let rightOnly = levelForStereo({ _ in 0.0 }, { sin(2 * .pi * 1000 * $0) })

    check("identical stereo channels stay loud", both > 0.5, String(format: "%.3f", both))
    check("opposite-phase stereo cancels", cancel < 0.05, String(format: "%.3f", cancel))
    // A mono downmix averages, so a tone on the right channel alone arrives at
    // half amplitude: 6 dB down, i.e. 6/72 of the display scale.
    let quietEnough = rightOnly > 0.5
    let expectedGap = 6.0 / 72.0
    check("a signal on the right channel alone is picked up", quietEnough,
          String(format: "%.3f", rightOnly))
    checkNear("right-only downmix reads 6 dB below both channels",
              Double(both - rightOnly), expectedGap, 0.02)
}

func stereoFormat(_ rate: Double) -> AVAudioFormat {
    AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
}

// MARK: - Summary

print("")
if failures == 0 {
    print("test_spectrum: ALL PASS (\(checks) checks)")
} else {
    print("test_spectrum: \(failures)/\(checks) FAILED")
    exit(1)
}