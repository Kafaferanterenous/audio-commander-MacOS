//! Linear predictor for APE decoding (v3.99+).
//!
//! Reconstructs audio samples from NNFilter'd residuals using adaptive
//! linear prediction with a sliding delay buffer.
//!
//! Based on FFmpeg's predictor_decode_mono_3950 / predictor_update_filter
//! (v3990 uses the v3950 predictor).

const HISTORY_SIZE: usize = 512;
const PREDICTOR_SIZE: usize = 50;

// Delay buffer offsets (relative to current buf position)
const YDELAYA: usize = 18 + 8 * 4; // 50
const YDELAYB: usize = 18 + 8 * 3; // 42
const XDELAYA: usize = 18 + 8 * 2; // 34
const XDELAYB: usize = 18 + 8;     // 26

// Adaptation sign positions (relative to current buf position)
const YADAPTCOEFFSA: usize = 18;
const XADAPTCOEFFSA: usize = 14;
const YADAPTCOEFFSB: usize = 10;
const XADAPTCOEFFSB: usize = 5;

/// Initial filter A coefficients for v3.93+.
const INITIAL_COEFFS_A: [i64; 4] = [360, 317, -109, 98];

/// APE sign function: returns -1 for positive, +1 for negative, 0 for zero.
fn apesign(x: i64) -> i64 {
    (if x < 0 { 1 } else { 0 }) - (if x > 0 { 1 } else { 0 })
}

/// The APE predictor — handles both mono and stereo.
pub struct Predictor {
    /// History buffer: HISTORY_SIZE + PREDICTOR_SIZE entries.
    buf: Vec<i64>,
    /// Current position in the history buffer (equivalent to FFmpeg's p->buf pointer).
    buf_pos: usize,
    /// Per-channel state.
    last_a: [i64; 2],
    filter_a: [i64; 2],
    filter_b: [i64; 2],
    coeffs_a: [[i64; 4]; 2],
    coeffs_b: [[i64; 5]; 2],
}

impl Predictor {
    pub fn new() -> Self {
        Predictor {
            buf: vec![0i64; HISTORY_SIZE + PREDICTOR_SIZE],
            buf_pos: 0,
            last_a: [0; 2],
            filter_a: [0; 2],
            filter_b: [0; 2],
            coeffs_a: [INITIAL_COEFFS_A, INITIAL_COEFFS_A],
            coeffs_b: [[0; 5]; 2],
        }
    }

    /// Reset predictor state at frame boundaries.
    pub fn reset(&mut self) {
        self.buf.fill(0);
        self.buf_pos = 0;
        self.last_a = [0; 2];
        self.filter_a = [0; 2];
        self.filter_b = [0; 2];
        self.coeffs_a = [INITIAL_COEFFS_A, INITIAL_COEFFS_A];
        self.coeffs_b = [[0; 5]; 2];
    }

    /// Decode a mono sample.
    pub fn decode_mono(&mut self, input: i32) -> i32 {
        let a = input as i64;
        let bp = self.buf_pos;

        // Write current prediction to delay line
        self.buf[bp + YDELAYA] = self.last_a[0];
        // Compute delta (overwrites previous value at that position)
        self.buf[bp + YDELAYA - 1] =
            self.buf[bp + YDELAYA].wrapping_sub(self.buf[bp + YDELAYA - 1]);

        // Prediction from 4 delayed values
        let prediction_a: i64 =
            self.buf[bp + YDELAYA]     .wrapping_mul(self.coeffs_a[0][0])
            .wrapping_add(self.buf[bp + YDELAYA - 1].wrapping_mul(self.coeffs_a[0][1]))
            .wrapping_add(self.buf[bp + YDELAYA - 2].wrapping_mul(self.coeffs_a[0][2]))
            .wrapping_add(self.buf[bp + YDELAYA - 3].wrapping_mul(self.coeffs_a[0][3]));

        // Reconstruct: output = input + (prediction >> 10)
        let current_a = a.wrapping_add(prediction_a >> 10);
        self.last_a[0] = current_a;

        // Write adaptation signs
        self.buf[bp + YADAPTCOEFFSA] = apesign(self.buf[bp + YDELAYA]);
        self.buf[bp + YADAPTCOEFFSA - 1] = apesign(self.buf[bp + YDELAYA - 1]);

        // Adapt coefficients
        let sign = apesign(a);
        if sign != 0 {
            self.coeffs_a[0][0] = self.coeffs_a[0][0]
                .wrapping_add(self.buf[bp + YADAPTCOEFFSA].wrapping_mul(sign));
            self.coeffs_a[0][1] = self.coeffs_a[0][1]
                .wrapping_add(self.buf[bp + YADAPTCOEFFSA - 1].wrapping_mul(sign));
            self.coeffs_a[0][2] = self.coeffs_a[0][2]
                .wrapping_add(self.buf[bp + YADAPTCOEFFSA - 2].wrapping_mul(sign));
            self.coeffs_a[0][3] = self.coeffs_a[0][3]
                .wrapping_add(self.buf[bp + YADAPTCOEFFSA - 3].wrapping_mul(sign));
        }

        // Advance buffer
        self.buf_pos += 1;

        // Wrap history buffer
        if self.buf_pos >= HISTORY_SIZE {
            // Copy last PREDICTOR_SIZE entries to the front
            for i in 0..PREDICTOR_SIZE {
                self.buf[i] = self.buf[self.buf_pos + i];
            }
            // Zero the rest
            for i in PREDICTOR_SIZE..self.buf.len() {
                self.buf[i] = 0;
            }
            self.buf_pos = 0;
        }

        // IIR feedback filter: filterA = currentA + (filterA * 31) >> 5
        self.filter_a[0] = current_a
            .wrapping_add(self.filter_a[0].wrapping_mul(31) >> 5);

        self.filter_a[0] as i32
    }

    /// Decode a stereo sample pair. Returns (left, right).
    pub fn decode_stereo(&mut self, input_y: i32, input_x: i32) -> (i32, i32) {
        // Y channel (channel 0)
        let decoded_y = self.update_filter(input_y as i64, 0, YDELAYA, YDELAYB,
                                           YADAPTCOEFFSA, YADAPTCOEFFSB);

        // X channel (channel 1)
        let decoded_x = self.update_filter(input_x as i64, 1, XDELAYA, XDELAYB,
                                           XADAPTCOEFFSA, XADAPTCOEFFSB);

        // Advance buffer
        self.buf_pos += 1;
        if self.buf_pos >= HISTORY_SIZE {
            for i in 0..PREDICTOR_SIZE {
                self.buf[i] = self.buf[self.buf_pos + i];
            }
            for i in PREDICTOR_SIZE..self.buf.len() {
                self.buf[i] = 0;
            }
            self.buf_pos = 0;
        }

        // Inverse channel decorrelation
        let left = decoded_x.wrapping_sub(decoded_y / 2) as i32;
        let right = left.wrapping_add(decoded_y as i32);

        (left, right)
    }

    /// Apply prediction filter for one sample on one channel (stereo path).
    fn update_filter(
        &mut self,
        decoded: i64,
        ch: usize,
        delay_a: usize,
        delay_b: usize,
        adapt_a: usize,
        adapt_b: usize,
    ) -> i64 {
        let bp = self.buf_pos;

        // Filter A: own-channel prediction
        self.buf[bp + delay_a] = self.last_a[ch];
        self.buf[bp + adapt_a] = apesign(self.buf[bp + delay_a]);
        self.buf[bp + delay_a - 1] =
            self.buf[bp + delay_a].wrapping_sub(self.buf[bp + delay_a - 1]);
        self.buf[bp + adapt_a - 1] = apesign(self.buf[bp + delay_a - 1]);

        let prediction_a: i64 =
            self.buf[bp + delay_a]    .wrapping_mul(self.coeffs_a[ch][0])
            .wrapping_add(self.buf[bp + delay_a - 1].wrapping_mul(self.coeffs_a[ch][1]))
            .wrapping_add(self.buf[bp + delay_a - 2].wrapping_mul(self.coeffs_a[ch][2]))
            .wrapping_add(self.buf[bp + delay_a - 3].wrapping_mul(self.coeffs_a[ch][3]));

        // Filter B: cross-channel prediction
        // B delay stores: filterA of the OTHER channel - IIR(filterB)
        self.buf[bp + delay_b] = self.filter_a[ch ^ 1]
            .wrapping_sub(self.filter_b[ch].wrapping_mul(31) >> 5);
        self.buf[bp + adapt_b] = apesign(self.buf[bp + delay_b]);
        self.buf[bp + delay_b - 1] =
            self.buf[bp + delay_b].wrapping_sub(self.buf[bp + delay_b - 1]);
        self.buf[bp + adapt_b - 1] = apesign(self.buf[bp + delay_b - 1]);
        self.filter_b[ch] = self.filter_a[ch ^ 1];

        let prediction_b: i64 =
            self.buf[bp + delay_b]    .wrapping_mul(self.coeffs_b[ch][0])
            .wrapping_add(self.buf[bp + delay_b - 1].wrapping_mul(self.coeffs_b[ch][1]))
            .wrapping_add(self.buf[bp + delay_b - 2].wrapping_mul(self.coeffs_b[ch][2]))
            .wrapping_add(self.buf[bp + delay_b - 3].wrapping_mul(self.coeffs_b[ch][3]))
            .wrapping_add(self.buf[bp + delay_b - 4].wrapping_mul(self.coeffs_b[ch][4]));

        // Reconstruct
        self.last_a[ch] = decoded
            .wrapping_add((prediction_a.wrapping_add(prediction_b >> 1)) >> 10);

        // IIR feedback
        self.filter_a[ch] = self.last_a[ch]
            .wrapping_add(self.filter_a[ch].wrapping_mul(31) >> 5);

        // Adapt coefficients A
        let sign = apesign(decoded);
        if sign != 0 {
            self.coeffs_a[ch][0] = self.coeffs_a[ch][0]
                .wrapping_add(self.buf[bp + adapt_a].wrapping_mul(sign));
            self.coeffs_a[ch][1] = self.coeffs_a[ch][1]
                .wrapping_add(self.buf[bp + adapt_a - 1].wrapping_mul(sign));
            self.coeffs_a[ch][2] = self.coeffs_a[ch][2]
                .wrapping_add(self.buf[bp + adapt_a - 2].wrapping_mul(sign));
            self.coeffs_a[ch][3] = self.coeffs_a[ch][3]
                .wrapping_add(self.buf[bp + adapt_a - 3].wrapping_mul(sign));

            // Adapt coefficients B
            self.coeffs_b[ch][0] = self.coeffs_b[ch][0]
                .wrapping_add(self.buf[bp + adapt_b].wrapping_mul(sign));
            self.coeffs_b[ch][1] = self.coeffs_b[ch][1]
                .wrapping_add(self.buf[bp + adapt_b - 1].wrapping_mul(sign));
            self.coeffs_b[ch][2] = self.coeffs_b[ch][2]
                .wrapping_add(self.buf[bp + adapt_b - 2].wrapping_mul(sign));
            self.coeffs_b[ch][3] = self.coeffs_b[ch][3]
                .wrapping_add(self.buf[bp + adapt_b - 3].wrapping_mul(sign));
            self.coeffs_b[ch][4] = self.coeffs_b[ch][4]
                .wrapping_add(self.buf[bp + adapt_b - 4].wrapping_mul(sign));
        }

        self.filter_a[ch]
    }
}
