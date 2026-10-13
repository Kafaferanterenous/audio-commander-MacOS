//! NNFilter — Adaptive FIR filter for APE decoding.
//!
//! The NNFilter is the core complexity of Monkey's Audio. For v3.98+, it uses
//! sign-magnitude adaptive coefficients with a running average threshold.
//!
//! Filter parameters vary by compression level:
//!   Level 1000 (Fast):       no filter
//!   Level 2000 (Normal):     1 stage, 16 taps, fracbits=11
//!   Level 3000 (High):       1 stage, 64 taps, fracbits=11
//!   Level 4000 (Extra High): 2 stages, 32+256 taps, fracbits=10,13
//!   Level 5000 (Insane):     3 stages, 16+256+1280 taps, fracbits=11,13,15

/// Maximum number of filter stages.
pub const MAX_STAGES: usize = 3;

/// Filter orders (taps) for each compression level, per stage.
/// Index = (compression_level / 1000) - 1, so 0=Fast, 1=Normal, etc.
pub const FILTER_ORDERS: [[u16; MAX_STAGES]; 5] = [
    [0, 0, 0],       // Fast (1000) — no filter
    [16, 0, 0],      // Normal (2000)
    [64, 0, 0],      // High (3000)
    [32, 256, 0],    // Extra High (4000)
    [16, 256, 1280], // Insane (5000)
];

/// Fractional bits (right-shift for rounding) per stage per compression level.
pub const FILTER_FRACBITS: [[u8; MAX_STAGES]; 5] = [
    [0, 0, 0],
    [11, 0, 0],
    [11, 0, 0],
    [10, 13, 0],
    [11, 13, 15],
];

const HISTORY_SIZE: usize = 512;

/// APE sign function: returns -1 for positive, +1 for negative, 0 for zero.
fn apesign(x: i32) -> i32 {
    (if x < 0 { 1 } else { 0 }) - (if x > 0 { 1 } else { 0 })
}

/// One stage of the adaptive FIR filter.
#[derive(Clone)]
pub struct NNFilterStage {
    /// Number of taps (filter order).
    order: usize,
    /// Fractional bits for rounding the dot product.
    fracbits: u8,
    /// Filter coefficients.
    coeffs: Vec<i16>,
    /// History buffer: holds both delay values and adapt coefficients.
    /// Layout: [adapt_init(order)] [adaptcoeffs(order)] [delay(HISTORY_SIZE)...]
    historybuffer: Vec<i16>,
    /// Current delay pointer position (index into historybuffer).
    delay_pos: usize,
    /// Current adaptcoeffs pointer position (index into historybuffer).
    adapt_pos: usize,
    /// Running average of |output|.
    avg: u32,
}

impl NNFilterStage {
    /// Create a new filter stage with the given order and fracbits.
    pub fn new(order: usize, fracbits: u8) -> Self {
        // Buffer layout: historybuffer[0..order*2+HISTORY_SIZE]
        // adaptcoeffs start at [order], delay starts at [order*2]
        let buf_size = order * 2 + HISTORY_SIZE;
        NNFilterStage {
            order,
            fracbits,
            coeffs: vec![0i16; order],
            historybuffer: vec![0i16; buf_size],
            delay_pos: order * 2,
            adapt_pos: order,
            avg: 0,
        }
    }

    /// Reset the filter state (called at frame boundaries).
    pub fn reset(&mut self) {
        self.coeffs.fill(0);
        self.historybuffer.fill(0);
        self.delay_pos = self.order * 2;
        self.adapt_pos = self.order;
        self.avg = 0;
    }

    /// Apply the filter to one sample (decompress direction).
    pub fn decompress(&mut self, input: i32) -> i32 {
        if self.order == 0 {
            return input;
        }

        let order = self.order;
        let dp = self.delay_pos;
        let ap = self.adapt_pos;
        let sign = apesign(input);

        // Dot product: sum(coeffs[i] * delay[dp - order + i])
        // AND adaptation: coeffs[i] += adaptcoeffs[ap - order + i] * sign
        let mut sum: i64 = 0;
        for i in 0..order {
            sum += self.coeffs[i] as i64 * self.historybuffer[dp - order + i] as i64;
            // Adapt simultaneously
            self.coeffs[i] = self.coeffs[i]
                .wrapping_add((self.historybuffer[ap - order + i] as i32 * sign) as i16);
        }

        // Round and shift
        let rounding = 1i64 << (self.fracbits as i64 - 1);
        let filtered = ((sum + rounding) >> self.fracbits) as i32;

        // Add residual
        let res = filtered.wrapping_add(input);

        // Write to delay line (clamped to i16)
        self.historybuffer[dp] = res.clamp(i16::MIN as i32, i16::MAX as i32) as i16;

        // Compute adaptive coefficient for current position (v3.98+ logic)
        let absres = res.unsigned_abs();
        let adapt_val = if absres != 0 {
            let avg3 = self.avg as u64 * 3;
            let avg_plus_third = self.avg as u64 + (self.avg as u64 / 3);
            let shift = (absres as u64 > avg3) as u32
                + (absres as u64 > avg_plus_third) as u32;
            apesign(res) * (8 << shift)
        } else {
            0
        };
        self.historybuffer[ap] = adapt_val as i16;

        // Update running average
        self.avg = ((self.avg as i64
            + (absres as i64 - self.avg as i64) / 16) as u32)
            .max(0);

        // Decay old adaptive coefficients
        if ap >= 1 {
            self.historybuffer[ap - 1] >>= 1;
        }
        if ap >= 2 {
            self.historybuffer[ap - 2] >>= 1;
        }
        if ap >= 8 {
            self.historybuffer[ap - 8] >>= 1;
        }

        // Advance pointers
        self.delay_pos += 1;
        self.adapt_pos += 1;

        // Wrap history buffer if needed
        if self.delay_pos >= order * 2 + HISTORY_SIZE {
            // Move the tail back to the front
            let tail_start = self.delay_pos - order * 2;
            for i in 0..(order * 2) {
                self.historybuffer[i] = self.historybuffer[tail_start + i];
            }
            self.delay_pos = order * 2;
            self.adapt_pos = order;
        }

        res
    }
}

/// Multi-stage NNFilter — cascades 0-3 filter stages.
pub struct NNFilter {
    stages: Vec<NNFilterStage>,
}

impl NNFilter {
    /// Create an NNFilter for the given compression level.
    /// `fset` = (compression_level / 1000) - 1, range 0..5.
    pub fn new(fset: usize) -> Self {
        let mut stages = Vec::new();
        for s in 0..MAX_STAGES {
            let order = FILTER_ORDERS[fset][s] as usize;
            if order > 0 {
                let fracbits = FILTER_FRACBITS[fset][s];
                stages.push(NNFilterStage::new(order, fracbits));
            }
        }
        NNFilter { stages }
    }

    /// Reset all filter stages.
    pub fn reset(&mut self) {
        for stage in &mut self.stages {
            stage.reset();
        }
    }

    /// Apply all filter stages to decompress one sample.
    /// Stages are applied in forward order (last encoded = first decoded).
    pub fn decompress(&mut self, mut value: i32) -> i32 {
        for stage in self.stages.iter_mut() {
            value = stage.decompress(value);
        }
        value
    }

    /// Number of active stages.
    pub fn num_stages(&self) -> usize {
        self.stages.len()
    }
}
