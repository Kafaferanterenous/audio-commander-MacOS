import Foundation

final class PullDecoder {
    private let ptr: UnsafeMutableRawPointer

    private static func openRaw(_ data: Data) -> UnsafeMutableRawPointer? {
        data.withUnsafeBytes { raw -> UnsafeMutableRawPointer? in
            guard let base = raw.baseAddress else { return nil }
            guard let h = dec_open(base, raw.count) else { return nil }
            return UnsafeMutableRawPointer(mutating: h)
        }
    }

    let duration: TimeInterval

    init?(data: Data) {
        guard let h = PullDecoder.openRaw(data) else { return nil }
        ptr = h
        duration = dec_duration(ptr)
    }

    convenience init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        self.init(data: data)
    }

    deinit { dec_close(ptr) }

    var sampleRate: UInt { UInt(dec_sample_rate(ptr)) }
    var channels: UInt { UInt(dec_channels(ptr)) }
    var position: TimeInterval { dec_position(ptr) }

    /// Renders up to `frames` interleaved stereo frames into out.
    /// Returns rendered count; 0 == end of stream.
    func render(into out: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        Int(dec_render(ptr, out, frames))
    }

    func seek(to seconds: TimeInterval) -> Bool {
        dec_seek(ptr, seconds) != 0
    }

    /// One-shot duration probe without keeping state. Thread-safe.
    static func probeDuration(url: URL) -> TimeInterval? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        let d = data.withUnsafeBytes { raw -> Double in
            guard let base = raw.baseAddress else { return 0 }
            return dec_probe_duration(base, raw.count)
        }
        return d.isFinite && d > 0 ? d : nil
    }
}
