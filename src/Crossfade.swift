import Foundation

/// `gapless` is a very short overlap: the incoming track starts just before the
/// outgoing one ends, so there is no silent teardown gap. The other value is
/// a true 3-second crossfade.
enum CrossfadeOption: Int, CaseIterable, Identifiable {
    case off, gapless, three

    var id: Int { rawValue }

    var overlap: Double {
        switch self {
        case .off: return 0
        case .gapless: return 0.08
        case .three: return 3
        }
    }

    /// Gapless is a very short overlap, so the incoming node starts at full
    /// volume instead of fading in.
    var isGapless: Bool { self == .gapless }
    var isEnabled: Bool { self != .off }

    var titleKey: String {
        switch self {
        case .off: return "xfOff"
        case .gapless: return "xfGapless"
        case .three: return "xfThree"
        }
    }
}

/// Pure transition maths, kept free of audio-framework types so the harness can
/// pin the boundaries that a fade bug would otherwise hide.
enum Crossfade {
    /// Gain for the incoming track, 0 at the start of the fade and 1 at the end.
    static func fadeIn(elapsed: Double, overlap: Double) -> Double {
        guard overlap > 0 else { return 1 }
        return min(1, max(0, elapsed / overlap))
    }

    /// Gain for the outgoing track, mirroring `fadeIn`.
    static func fadeOut(elapsed: Double, overlap: Double) -> Double {
        1 - fadeIn(elapsed: elapsed, overlap: overlap)
    }

    /// True once the outgoing track is within `overlap` seconds of its end and
    /// the transition should begin. Never true at or past the end (the normal
    /// end-of-track path owns that), never true when disabled.
    static func shouldTransition(position: Double, duration: Double,
                                 overlap: Double) -> Bool {
        guard duration > 0, overlap > 0 else { return false }
        return position >= duration - overlap && position < duration
    }
}
