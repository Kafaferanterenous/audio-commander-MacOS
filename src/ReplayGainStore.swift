import Foundation
import Combine
import AVFoundation

/// PCM lifting: turns any playable audio file into mono Float samples for
/// `ReplayGain.measure`. Native formats go through AVAudioFile; the embedded
/// formats (trackers, Vorbis, WavPack, VOC) through the pull decoder.
enum ReplayGainDecoder {
    enum Failure: Error { case unreadable }

    static func monoSamples(url: URL) throws -> (samples: [Float], rate: Double) {
        if let native = try? readNative(url: url) { return native }
        if let embedded = try? readEmbedded(url: url) { return embedded }
        throw Failure.unreadable
    }

    private static func readNative(url: URL) throws -> (samples: [Float], rate: Double) {
        let file = try AVAudioFile(forReading: url)
        let rate = Double(file.processingFormat.sampleRate)
        let channels = max(1, Int(file.processingFormat.channelCount))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: 65_536)!
        var out: [Float] = []
        out.reserveCapacity(Int(file.length))
        while true {
            do { try file.read(into: buffer) } catch { break }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            out.reserveCapacity(out.count + frames)
            for f in 0..<frames {
                var acc: Float = 0
                for c in 0..<channels { acc += data[c][f] }
                out.append(acc / Float(channels))
            }
            if frames < buffer.frameCapacity { break }
        }
        return (out, rate)
    }

    private static func readEmbedded(url: URL) throws -> (samples: [Float], rate: Double) {
        guard let dec = PullDecoder(url: url) else { throw Failure.unreadable }
        let frames = 65_536
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        defer { scratch.deallocate() }
        var out: [Float] = []
        while true {
            let got = dec.render(into: scratch, frames: frames)
            guard got > 0 else { break }
            out.reserveCapacity(out.count + got)
            for i in 0..<got {
                out.append((scratch[i * 2] + scratch[i * 2 + 1]) * 0.5)
            }
            if got < frames { break }
        }
        return (out, Double(dec.sampleRate))
    }
}

/// ReplayGain state and orchestration (#19).
///
/// Measurement is heavy, so `scan` lifts the decode + analysis into a detached
/// task; state mutation (cache, `isScanning`) stays on the main actor. The
/// result is stored as a `.replaygain` sidecar JSON next to each track — the
/// original file is never touched, which keeps the feature reversible and
/// format-neutral.
@MainActor
final class ReplayGainStore: ObservableObject {
    static let shared = ReplayGainStore()

    @Published var mode: ReplayGainMode = .off {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "ac_replaygain_mode")
        }
    }
    @Published private(set) var isScanning = false
    /// Short, localized progress/result line for the Effects tab.
    @Published var status: String?

    /// In-memory sidecar cache: populated lazily per track, costs nothing
    /// unless the user has actually analysed something.
    private var cache: [URL: ReplayGainEntry] = [:]

    private init() {
        let raw = UserDefaults.standard.string(forKey: "ac_replaygain_mode") ?? ""
        mode = ReplayGainMode(rawValue: raw) ?? .off
    }

    // MARK: Sidecar access

    nonisolated static func sidecarURL(for track: URL) -> URL {
        track.deletingPathExtension().appendingPathExtension("replaygain")
    }

    /// Reads (and caches) a track's sidecar, or nil if it has never been
    /// analysed (or the file moved).
    func entry(for track: URL) -> ReplayGainEntry? {
        if let cached = cache[track] { return cached }
        let url = ReplayGainStore.sidecarURL(for: track)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(ReplayGainEntry.self, from: data)
        else { return nil }
        cache[track] = entry
        return entry
    }

    func clearCache() { cache.removeAll() }

    // MARK: Gain application

    /// Linear multiplier to fold into the master volume for `track`. Off or
    /// un-analysed tracks pass through at 1.0. Boosts are clamped so the gain
    /// never pushes the true peak past full scale; cuts apply exactly.
    func volumeMultiplier(for track: URL?, mode: ReplayGainMode) -> Double {
        guard mode != .off, let track else { return 1 }
        guard let entry = entry(for: track) else { return 1 }
        let gain: Double
        let peak: Float
        switch mode {
        case .off:
            return 1
        case .track:
            guard entry.trackLoudnessLUFS != nil else { return 1 }
            gain = entry.trackGain
            peak = entry.trackPeak
        case .album:
            guard let album = entry.albumGain else { return 1 }
            gain = album
            peak = entry.albumPeak ?? entry.trackPeak
        }
        guard gain.isFinite else { return 1 }
        if gain <= 0 { return pow(10, gain / 20) }
        let headroom = -20 * log10(Double(max(peak, 1e-4)))
        return pow(10, min(gain, headroom) / 20)
    }

    // MARK: Scanning

    /// Analyses one track and writes its sidecar. Returns the entry.
    func scan(track: URL) async -> ReplayGainEntry? {
        guard !isScanning else { return nil }
        isScanning = true
        let entry = await Task.detached(priority: .userInitiated) {
            ReplayGainStore.scanSync(track: track)
        }.value
        isScanning = false
        if let entry { cache[track] = entry }
        return entry
    }

    /// Analyses every audio file in `folder`, then writes each sidecar's
    /// album gain (mean track loudness, max peak). Returns how many succeeded.
    func scan(folder: URL) async -> Int {
        guard !isScanning else { return 0 }
        isScanning = true
        defer { isScanning = false }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        let audio = files.filter { $0.isFileURL && RGSupported.isSupportedExtension($0.pathExtension) }
        let results = await Task.detached(priority: .userInitiated) {
            var entries: [URL: ReplayGainEntry] = [:]
            for url in audio {
                if let entry = ReplayGainStore.scanSync(track: url) { entries[url] = entry }
            }
            let loudness = entries.values.compactMap(\.trackLoudnessLUFS)
            if !loudness.isEmpty {
                let albumGain = ReplayGain.referenceLevel
                    - loudness.reduce(0, +) / Double(loudness.count)
                let albumPeak = entries.values.map(\.trackPeak).max() ?? 0
                for (url, entry) in entries {
                    var updated = entry
                    updated.albumGain = albumGain
                    updated.albumPeak = albumPeak
                    ReplayGainStore.writeSidecar(entry: updated, for: url)
                }
            }
            return entries
        }.value
        for (url, entry) in results { cache[url] = entry }
        return results.count
    }

    /// Removes a track's sidecar and cache entry (metadata undo).
    func clear(track: URL) {
        cache[track] = nil
        try? FileManager.default.removeItem(at: ReplayGainStore.sidecarURL(for: track))
    }

    // MARK: Off-main worker

    nonisolated static func scanSync(track: URL) -> ReplayGainEntry? {
        guard let (samples, rate) = try? ReplayGainDecoder.monoSamples(url: track) else { return nil }
        let result = ReplayGain.measure(mono: samples, sampleRate: rate)
        let entry = ReplayGainEntry(version: 1,
                                    trackLoudnessLUFS: result.loudnessLUFS,
                                    trackGain: result.gainDB,
                                    trackPeak: result.peak,
                                    albumGain: nil,
                                    albumPeak: nil,
                                    scannedAt: Date())
        writeSidecar(entry: entry, for: track)
        return entry
    }

    nonisolated static func writeSidecar(entry: ReplayGainEntry, for track: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(entry) else { return }
        try? data.write(to: sidecarURL(for: track), options: .atomic)
    }
}

/// Extension filter for folder scans: everything the app can actually play
/// (native + embedded), minus MIDI (synthesized; loudness is meaningless).
enum RGSupported {
    static func isSupportedExtension(_ ext: String) -> Bool {
        let e = ext.lowercased()
        return (AudioFormats.nativeExtensions.contains(e)
            || AudioFormats.embeddedExtensions.contains(e))
            && !AudioFormats.midiExtensions.contains(e)
    }
}