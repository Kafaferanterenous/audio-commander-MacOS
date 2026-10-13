//! Arithmetic range coder for APE entropy decoding.
//!
//! Matches FFmpeg's apedec.c control flow exactly:
//! - normalize() is called at the START of each decode (culfreq/culshift)
//! - update() does NOT normalize
//! - The buffer register carries bits between bytes via EXTRA_BITS mechanism

// ── Range coder constants ────────────────────────────────────────────

const CODE_BITS: u32 = 32;
const TOP_VALUE: u32 = 1u32 << (CODE_BITS - 1);
const BOTTOM_VALUE: u32 = TOP_VALUE >> 8;
const EXTRA_BITS: u32 = ((CODE_BITS - 2) % 8) + 1; // = 7

/// Number of symbols in the frequency model table.
const MODEL_ELEMENTS: usize = 22;

/// Cumulative frequency table for v3.98+ (version >= 3980).
const COUNTS_3980: [u16; MODEL_ELEMENTS] = [
    0, 19578, 36160, 48417, 56323, 60899, 63265, 64435, 64971, 65232, 65351,
    65416, 65447, 65466, 65476, 65482, 65485, 65488, 65490, 65491, 65492,
    65493,
];

/// Differential (per-symbol width) frequency table for v3.98+.
const COUNTS_DIFF_3980: [u16; MODEL_ELEMENTS - 1] = [
    19578, 16582, 12257, 7906, 4576, 2366, 1170, 536, 261, 119, 65, 31, 19,
    10, 6, 3, 3, 2, 1, 1, 1,
];

// ── Rice state ───────────────────────────────────────────────────────

/// Adaptive parameter for the Golomb-Rice–like pivot computation.
#[derive(Debug, Clone)]
pub struct RiceState {
    pub k: u32,
    pub ksum: u32,
}

impl RiceState {
    pub fn new() -> Self {
        RiceState {
            k: 10,
            ksum: 1 << 14, // 16384: initial pivot = 512
        }
    }

    /// Update the adaptive parameters after decoding a value.
    /// Matches FFmpeg's update_rice exactly: single-expression ksum update.
    pub fn update(&mut self, x: u32) {
        // FFmpeg: rice->ksum += ((x + 1) / 2) - ((rice->ksum + 16) >> 5);
        // Must use ORIGINAL ksum for the subtraction term.
        let add = x.wrapping_add(1) / 2;
        let sub = self.ksum.wrapping_add(16) >> 5;
        self.ksum = self.ksum.wrapping_add(add).wrapping_sub(sub);

        // FFmpeg: int lim = rice->k ? (1 << (rice->k + 4)) : 0;
        let lim = if self.k > 0 { 1u32 << (self.k + 4) } else { 0 };
        if self.ksum < lim {
            self.k -= 1;
        } else if self.ksum >= (1u32 << (self.k + 5)) && self.k < 24 {
            self.k += 1;
        }
    }

    /// The expected magnitude of the next value.
    pub fn pivot(&self) -> u32 {
        (self.ksum >> 5).max(1)
    }
}

// ── Range coder ──────────────────────────────────────────────────────

/// Byte-level range coder for entropy decoding.
///
/// Follows FFmpeg's apedec.c structure exactly:
/// - culshift/culfreq normalize BEFORE computing
/// - update does NOT normalize
pub struct RangeCoder<'a> {
    data: &'a [u8],
    pub pos: usize,
    /// Accumulated byte buffer (carries bits between normalize steps).
    pub buffer: u32,
    pub low: u32,
    pub range: u32,
    help: u32,
}

impl<'a> RangeCoder<'a> {
    /// Initialize the range coder from a byte slice (compressed frame data).
    /// Matches FFmpeg's range_start_decoding — does NOT normalize.
    pub fn new(data: &'a [u8]) -> Self {
        let mut rc = RangeCoder {
            data,
            pos: 0,
            buffer: 0,
            low: 0,
            range: 1u32 << EXTRA_BITS,
            help: 0,
        };

        // Read first byte into buffer, extract EXTRA_BITS for low
        rc.buffer = rc.read_byte() as u32;
        rc.low = rc.buffer >> (8 - EXTRA_BITS);

        // Do NOT normalize here — first culshift/culfreq call will normalize
        rc
    }

    /// Read the next byte, returning 0 on EOF.
    fn read_byte(&mut self) -> u8 {
        if self.pos < self.data.len() {
            let b = self.data[self.pos];
            self.pos += 1;
            b
        } else {
            0
        }
    }

    /// Renormalize: expand range by reading bytes until range > BOTTOM_VALUE.
    fn normalize(&mut self) {
        while self.range <= BOTTOM_VALUE {
            self.buffer = (self.buffer << 8) | (self.read_byte() as u32);
            self.low = (self.low << 8) | ((self.buffer >> 1) & 0xFF);
            self.range <<= 8;
        }
    }

    /// FFmpeg's range_decode_culshift: normalize, then decode uniform in [0, 2^shift).
    fn culshift(&mut self, shift: u32) -> u32 {
        self.normalize();
        self.help = self.range >> shift;
        self.low / self.help
    }

    /// FFmpeg's range_decode_culfreq: normalize, then decode uniform in [0, tot_f).
    fn culfreq(&mut self, tot_f: u32) -> u32 {
        self.normalize();
        self.help = self.range / tot_f;
        self.low / self.help
    }

    /// FFmpeg's range_decode_update: update state (does NOT normalize).
    fn update(&mut self, sy_f: u32, lt_f: u32) {
        self.low -= self.help * lt_f;
        self.range = self.help * sy_f;
    }

    /// FFmpeg's range_decode_bits: culshift + update(1, sym).
    fn decode_bits(&mut self, n: u32) -> u32 {
        let sym = self.culshift(n);
        self.update(1, sym);
        sym
    }

    /// Decode a symbol from the frequency model (counts_3980).
    /// Matches FFmpeg's range_get_symbol exactly.
    fn get_symbol(&mut self) -> u32 {
        let cf = self.culshift(16);

        // FFmpeg's fast path for rare/overflow symbols (cf > 65492)
        if cf > 65492 {
            let symbol = cf.wrapping_sub(65535).wrapping_add(63);
            self.update(1, cf);
            return symbol;
        }

        // Binary search: find largest lo where COUNTS_3980[lo] <= cf.
        // The cf > 65492 fast path above guarantees lo will be at most 20
        // (since cf <= 65492 means cf < COUNTS_3980[21] = 65493).
        let mut lo = 0usize;
        let mut hi = MODEL_ELEMENTS - 1;
        while lo < hi {
            let mid = (lo + hi + 1) / 2;
            if (COUNTS_3980[mid] as u32) <= cf {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }

        self.update(COUNTS_DIFF_3980[lo] as u32, COUNTS_3980[lo] as u32);
        lo as u32
    }

    /// Decode a single signed audio value using the APE v3.99 entropy scheme.
    /// Matches FFmpeg's ape_decode_value_3990 exactly.
    pub fn decode_value(&mut self, rice: &mut RiceState) -> i32 {
        let pivot = rice.pivot();

        // Decode overflow FIRST (always)
        let mut overflow = self.get_symbol();

        // Escape: symbol 63 (MODEL_ELEMENTS-1 in FFmpeg where MODEL_ELEMENTS=64)
        // In our table, symbols 21-62 come from the cf>65492 fast path,
        // symbol 63 triggers the escape.
        if overflow == 63 {
            overflow = (self.decode_bits(16)) << 16;
            overflow |= self.decode_bits(16);
        }

        // Decode base
        let base;
        if pivot < 0x10000 {
            base = self.culfreq(pivot);
            self.update(1, base);
        } else {
            let mut base_hi = pivot;
            let mut bbits = 0u32;
            while base_hi & !0xFFFF != 0 {
                base_hi >>= 1;
                bbits += 1;
            }
            let hi = self.culfreq(base_hi + 1);
            self.update(1, hi);
            let lo = self.culfreq(1u32 << bbits);
            self.update(1, lo);
            base = (hi << bbits) + lo;
        }

        let x = base.wrapping_add(overflow.wrapping_mul(pivot));
        rice.update(x);

        // Zigzag decode: matches FFmpeg's ((x >> 1) ^ ((x & 1) - 1)) + 1
        if x & 1 != 0 {
            ((x >> 1) as i32).wrapping_add(1)
        } else {
            -((x >> 1) as i32)
        }
    }
}
