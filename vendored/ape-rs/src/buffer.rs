//! Sample buffer for decoded PCM output.
//!
//! Handles frame-boundary buffering and stereo interleaving.

/// Buffer that accumulates decoded samples from a frame and yields them
/// one at a time through the iterator interface.
pub struct SampleBuffer {
    /// Decoded samples, interleaved for stereo: [L0, R0, L1, R1, ...]
    samples: Vec<i32>,
    /// Current read position.
    pos: usize,
}

impl SampleBuffer {
    pub fn new() -> Self {
        SampleBuffer {
            samples: Vec::new(),
            pos: 0,
        }
    }

    /// Push a mono sample.
    pub fn push(&mut self, sample: i32) {
        self.samples.push(sample);
    }

    /// Push a stereo sample pair (left, right).
    pub fn push_stereo(&mut self, left: i32, right: i32) {
        self.samples.push(left);
        self.samples.push(right);
    }

    /// Get the next sample, or None if buffer is exhausted.
    pub fn next_sample(&mut self) -> Option<i32> {
        if self.pos < self.samples.len() {
            let s = self.samples[self.pos];
            self.pos += 1;
            Some(s)
        } else {
            None
        }
    }

    /// Clear the buffer for reuse.
    pub fn clear(&mut self) {
        self.samples.clear();
        self.pos = 0;
    }

    /// Whether all samples have been consumed.
    pub fn is_empty(&self) -> bool {
        self.pos >= self.samples.len()
    }

    /// Number of remaining samples.
    pub fn remaining(&self) -> usize {
        self.samples.len() - self.pos
    }
}
