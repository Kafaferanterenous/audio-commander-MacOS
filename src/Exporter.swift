import Foundation
import AVFoundation
import Combine

/// Export / convert (#26) orchestration.
///
/// Decoding is reused wholesale: native formats through AVAudioFile, the
/// embedded exotic ones through the same PullDecoder playback uses. One
/// detached worker runs per file (decode -> gain -> dither -> container), and
/// each result carries a loudness report so the conversion can be checked.
@MainActor
final class Exporter: ObservableObject {
    static let shared = Exporter()

    @Published var isPresented = false
    @Published private(set) var sources: [URL] = []
    @Published var options: ExportOptions {
        didSet { persist() }
    }
    @Published var destination: URL?
    @Published private(set) var isRunning = false
    @Published private(set) var progress: Double = 0
    @Published var statusText: String?
    @Published private(set) var reports: [ExportReport] = []

    private init() {
        options = Exporter.loadOptions()
    }

    // MARK: Presentation

    /// Opens the sheet for the given files (order preserved, duplicates and
    /// non-audio entries dropped).
    func begin(urls: [URL]) {
        var seen = Set<String>()
        let audio = urls.filter { url in
            guard AudioFormats.isAudioFile(url.lastPathComponent) else { return false }
            guard !seen.contains(url.path) else { return false }
            seen.insert(url.path)
            return true
        }
        guard !audio.isEmpty else {
            statusText = AppSettings.shared.t("exportNothing")
            return
        }
        sources = audio
        reports = []
        statusText = nil
        progress = 0
        isPresented = true
    }

    func begin(items: [FileItem]) {
        begin(urls: items.filter { !$0.isDirectory && $0.isAudio }.map(\.url))
    }

    func cancel() {
        guard !isRunning else { return }
        isPresented = false
    }

    // MARK: Run

    func run() {
        guard !isRunning, !sources.isEmpty else { return }
        let jobs = sources
        let opts = options
        let dest = destination

        // ReplayGain gains must be read on the main actor before we go off it.
        var gains: [URL: Double] = [:]
        if opts.replayGain {
            for url in jobs {
                if let entry = ReplayGainStore.shared.entry(for: url),
                   entry.trackLoudnessLUFS != nil {
                    gains[url] = entry.trackGain
                }
            }
        }

        isRunning = true
        reports = []
        progress = 0
        statusText = nil

        let strings = WorkerStrings(noDecode: AppSettings.shared.t("exportNoDecode"),
                                    writeFailed: AppSettings.shared.t("exportWriteFailed"))

        Task {
            var acc: [ExportReport] = []
            for (index, url) in jobs.enumerated() {
                let gain = gains[url]
                let report = await Task.detached(priority: .userInitiated) {
                    Exporter.exportOne(url: url, options: opts,
                                       destination: dest, replayGainDB: gain,
                                       strings: strings)
                }.value
                acc.append(report)
                self.reports = acc
                self.progress = Double(index + 1) / Double(jobs.count)
            }
            self.isRunning = false
            let ok = acc.filter(\.ok).count
            self.statusText = ok == acc.count
                ? AppSettings.shared.tf("exportDone", ok)
                : AppSettings.shared.tf("exportPartial", ok, acc.count)
        }
    }

    // MARK: Options persistence

    private static func loadOptions() -> ExportOptions {
        let d = UserDefaults.standard
        var o = ExportOptions()
        if let f = d.string(forKey: "ac_export_format"),
           let format = ExportFormat(rawValue: f) { o.format = format }
        if let dp = d.string(forKey: "ac_export_depth"),
           let depth = ExportBitDepth(rawValue: dp) { o.depth = depth }
        o.dither = d.object(forKey: "ac_export_dither") as? Bool ?? o.dither
        o.noiseShaping = d.object(forKey: "ac_export_shaping") as? Bool ?? o.noiseShaping
        o.normalize = d.bool(forKey: "ac_export_normalize")
        o.replayGain = d.bool(forKey: "ac_export_replaygain")
        if !o.format.supports(o.depth) { o.depth = o.format.allowedDepths[0] }
        return o
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(options.format.rawValue, forKey: "ac_export_format")
        d.set(options.depth.rawValue, forKey: "ac_export_depth")
        d.set(options.dither, forKey: "ac_export_dither")
        d.set(options.noiseShaping, forKey: "ac_export_shaping")
        d.set(options.normalize, forKey: "ac_export_normalize")
        d.set(options.replayGain, forKey: "ac_export_replaygain")
    }

    // MARK: Worker (off the main actor)

    /// Localized messages precomputed on the main actor: the worker runs
    /// detached and must not reach back into AppSettings (which is @MainActor).
    struct WorkerStrings {
        var noDecode: String
        var writeFailed: String
    }

    struct Decoded {
        var samples: [Float]
        var channels: Int
        var sampleRate: Int
    }

    enum Failure: Error { case unsupported, decode, empty, write }

    nonisolated static func exportOne(url: URL, options: ExportOptions,
                                      destination: URL?, replayGainDB: Double?,
                                      strings: WorkerStrings) -> ExportReport {
        let format = options.format
        var depth = options.depth
        if !format.supports(depth) { depth = format.allowedDepths[0] }

        func fail(_ message: String) -> ExportReport {
            ExportReport(sourceName: url.lastPathComponent, outputPath: nil,
                         format: format, depth: depth, frames: 0, sampleRate: 0,
                         channels: 0, gainDB: 0, loudnessLUFS: nil, peakDBFS: -.infinity,
                         truePeakDBTP: -.infinity, ok: false, error: message)
        }

        guard let decoded = try? decode(url: url), !decoded.samples.isEmpty,
              decoded.channels > 0 else {
            return fail(strings.noDecode)
        }

        // Loudness/peak of the source material (what normalization acts on).
        let mono = downmix(decoded.samples, channels: decoded.channels)
        let measure = ReplayGain.measure(mono: mono, sampleRate: Double(decoded.sampleRate))
        let peakDBFS = measure.peak > 0 ? 20 * log10(Double(measure.peak)) : -.infinity

        // Gain: ReplayGain wins when a measurement exists, else peak normalize.
        var gainDB = 0.0
        if options.replayGain, let g = replayGainDB {
            gainDB = g
        } else if options.normalize {
            gainDB = ExportPCM.peakNormalizeGainDB(decoded.samples)
        }

        var samples = ExportPCM.applyGain(decoded.samples, db: gainDB)
        if options.dither, !depth.isFloat {
            samples = ExportPCM.dither(samples, channels: decoded.channels,
                                       scale: depth.scale,
                                       noiseShaping: options.noiseShaping,
                                       seed: UInt64(0x5EED_0000_0000) &+ UInt64(decoded.channels))
        }

        let truePeak = ExportTruePeak.dbtp(interleaved: samples, channels: decoded.channels)

        let outURL = outputURL(for: url, format: format, destination: destination)
        let frames = samples.count / decoded.channels

        let wrote: Bool
        switch format {
        case .wav:
            wrote = (try? ExportWriter.data(interleaved: samples, channels: decoded.channels,
                                            sampleRate: decoded.sampleRate, depth: depth)
                .write(to: outURL, options: .atomic)) != nil
        case .aiff:
            wrote = (try? ExportWriter.aiffData(interleaved: samples, channels: decoded.channels,
                                                sampleRate: decoded.sampleRate, depth: depth)
                .write(to: outURL, options: .atomic)) != nil
        case .flac:
            wrote = writeFLAC(samples: samples, channels: decoded.channels,
                              sampleRate: decoded.sampleRate, depth: depth, to: outURL)
        }

        guard wrote else { return fail(strings.writeFailed) }

        return ExportReport(sourceName: url.lastPathComponent,
                            outputPath: outURL.path,
                            format: format, depth: depth,
                            frames: frames, sampleRate: decoded.sampleRate,
                            channels: decoded.channels, gainDB: gainDB,
                            loudnessLUFS: measure.loudnessLUFS,
                            peakDBFS: peakDBFS, truePeakDBTP: truePeak,
                            ok: true, error: nil)
    }

    // MARK: Decoding

    nonisolated static func decode(url: URL) throws -> Decoded {
        switch AudioFormats.route(forExtension: url.pathExtension) {
        case .native: return try decodeNative(url: url)
        case .embedded: return try decodeEmbedded(url: url)
        case .midi: throw Failure.unsupported
        }
    }

    private nonisolated static func decodeNative(url: URL) throws -> Decoded {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let channels = max(1, Int(fmt.channelCount))
        let rate = Int(fmt.sampleRate.rounded())
        guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 32_768) else {
            throw Failure.decode
        }
        var inter = [Float]()
        inter.reserveCapacity(Int(file.length) * channels)
        while true {
            do { try file.read(into: buffer) } catch { break }
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { break }
            inter.reserveCapacity(inter.count + n * channels)
            for f in 0..<n {
                for c in 0..<channels { inter.append(data[c][f]) }
            }
            if n < Int(buffer.frameCapacity) { break }
        }
        guard !inter.isEmpty else { throw Failure.empty }
        return Decoded(samples: inter, channels: channels, sampleRate: rate)
    }

    private nonisolated static func decodeEmbedded(url: URL) throws -> Decoded {
        guard let dec = PullDecoder(url: url) else { throw Failure.decode }
        let block = 65_536
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: block * 2)
        defer { scratch.deallocate() }
        var inter = [Float]()
        while true {
            let got = dec.render(into: scratch, frames: block)
            guard got > 0 else { break }
            inter.append(contentsOf: UnsafeBufferPointer(start: scratch, count: got * 2))
            if got < block { break }
        }
        guard !inter.isEmpty else { throw Failure.empty }
        return Decoded(samples: inter, channels: 2, sampleRate: Int(dec.sampleRate))
    }

    nonisolated static func downmix(_ interleaved: [Float], channels: Int) -> [Float] {
        guard channels > 1 else { return interleaved }
        let frames = interleaved.count / channels
        var mono = [Float](repeating: 0, count: frames)
        let inv = 1 / Float(channels)
        for f in 0..<frames {
            var acc: Float = 0
            for c in 0..<channels { acc += interleaved[f * channels + c] }
            mono[f] = acc * inv
        }
        return mono
    }

    private nonisolated static func writeFLAC(samples: [Float], channels: Int,
                                              sampleRate: Int, depth: ExportBitDepth,
                                              to url: URL) -> Bool {
        let bits: UInt32 = depth == .int16 ? 16 : 24
        let result = samples.withUnsafeBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return 0 }
            return url.path.withCString { cpath in
                ac_flac_encode_file(base, buf.count / channels, UInt32(channels),
                                    UInt32(sampleRate), bits, 5, cpath)
            }
        }
        return result == 1
    }

    /// Destination file, never overwriting: "name.flac", "name (exported).flac",
    /// "name (exported 2).flac", ...
    nonisolated static func outputURL(for source: URL, format: ExportFormat,
                                      destination: URL?) -> URL {
        let dir = destination ?? source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let ext = format.fileExtension
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent("\(base).\(ext)")
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        candidate = dir.appendingPathComponent("\(base) (exported).\(ext)")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) (exported \(n)).\(ext)")
            n += 1
        }
        return candidate
    }
}
