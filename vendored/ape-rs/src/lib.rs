#![allow(dead_code)]

//! Pure Rust decoder for Monkey's Audio (APE) lossless audio files.
//!
//! Implemented from publicly available format documentation:
//! - Monkey's Audio SDK header definitions (APE_DESCRIPTOR, APE_HEADER)
//! - MultimediaWiki format description
//! - Public Monkey's Audio theory documentation
//!
//! No code derived from the MAC SDK reference implementation, NihAV, or any
//! AGPL/proprietary source.
//!
//! # Example
//!
//! ```no_run
//! use ape_rs::ApeReader;
//!
//! let mut reader = ApeReader::open("track.ape").unwrap();
//! let info = reader.info();
//! println!("{}ch, {}Hz, {}bit", info.channels, info.sample_rate, info.bits_per_sample);
//!
//! let samples: Vec<i32> = reader.samples().collect::<Result<_, _>>().unwrap();
//! ```

mod buffer;
mod decode;
pub mod error;
pub mod ffi;
mod header;
mod nnfilter;
mod predictor;
mod range_coder;

use std::fs::File;
use std::io::{BufReader, Read, Seek};
use std::path::Path;

pub use error::ApeError;

/// Metadata about the audio contained in an APE file.
#[derive(Debug, Clone)]
pub struct ApeInfo {
    /// Sample rate in Hz (e.g. 44100).
    pub sample_rate: u32,
    /// Number of audio channels (1 = mono, 2 = stereo).
    pub channels: u16,
    /// Bits per sample (8, 16, or 24).
    pub bits_per_sample: u16,
    /// Total number of audio samples (blocks × channels).
    pub total_samples: u64,
    /// Compression level (1000=Fast, 2000=Normal, 3000=High, 4000=Extra High, 5000=Insane).
    pub compression_level: u16,
    /// Format version (e.g. 3990 for v3.99).
    pub format_version: u16,
}

/// A reader that decodes Monkey's Audio (APE) files.
///
/// Modeled after `shorten_rs::ShnReader` — open a file, read metadata, then
/// iterate over decoded PCM samples.
pub struct ApeReader<R: Read + Seek> {
    decoder: decode::Decoder<R>,
    info: ApeInfo,
}

impl ApeReader<BufReader<File>> {
    /// Open an APE file by path.
    pub fn open<P: AsRef<Path>>(path: P) -> Result<Self, ApeError> {
        let file = File::open(path)?;
        let reader = BufReader::new(file);
        Self::new(reader)
    }
}

impl<R: Read + Seek> ApeReader<R> {
    /// Create a new ApeReader from any `Read + Seek` source.
    ///
    /// Parses the APE header immediately. After construction, call `info()`
    /// for metadata and `samples()` for audio.
    pub fn new(mut reader: R) -> Result<Self, ApeError> {
        let file_header = header::parse_header(&mut reader)?;

        let info = ApeInfo {
            sample_rate: file_header.header.sample_rate,
            channels: file_header.header.channels,
            bits_per_sample: file_header.header.bits_per_sample,
            total_samples: file_header.total_samples(),
            compression_level: file_header.header.compression_level,
            format_version: file_header.descriptor.version,
        };

        let decoder = decode::Decoder::new(reader, file_header);

        Ok(ApeReader { decoder, info })
    }

    /// Get metadata about the audio stream.
    pub fn info(&self) -> &ApeInfo {
        &self.info
    }

    /// Returns an iterator that yields decoded PCM samples as `Result<i32>`.
    ///
    /// Samples are interleaved for stereo files:
    /// `[L0, R0, L1, R1, ...]`
    ///
    /// Values are native i32 — the consumer should normalize using
    /// `bits_per_sample` (e.g. divide by 32768 for 16-bit to get f32).
    pub fn samples(&mut self) -> ApeSamples<'_, R> {
        ApeSamples {
            decoder: &mut self.decoder,
        }
    }

    /// Total per-channel sample frames in the stream.
    pub fn total_blocks(&self) -> u64 {
        self.decoder.header.total_blocks()
    }

    /// Per-channel samples in a full frame — the granularity of a seek.
    pub fn blocks_per_frame(&self) -> u32 {
        self.decoder.blocks_per_frame()
    }

    /// Seek to an absolute per-channel sample index (clamped to the end).
    ///
    /// APE frames decode independently, so this restarts at the containing
    /// frame and silently drops the samples preceding `sample`; the next item
    /// from `samples()` is then exactly `sample`.
    pub fn seek_sample(&mut self, sample: u64) {
        let blocks = self.decoder.blocks_per_frame() as u64;
        let total = self.total_blocks();
        let target = if sample > total { total } else { sample };
        let (frame, rem) = if blocks == 0 {
            (0u32, 0u64)
        } else {
            ((target / blocks) as u32, target % blocks)
        };
        self.decoder.seek_to_frame(frame);

        let channels = self.info.channels as usize;
        let mut drop = (rem as usize) * channels;
        while drop > 0 {
            if self.decoder.next_sample().is_some() {
                drop -= 1;
            } else if self.decoder.finished {
                break;
            } else if !self.decoder.decode_next_frame().unwrap_or(false) {
                break;
            }
        }
    }
}

/// Iterator over decoded PCM samples from an APE file.
///
/// Each call to `next()` yields one sample as `Result<i32, ApeError>`.
/// For stereo files, samples alternate between channels.
pub struct ApeSamples<'a, R: Read + Seek> {
    decoder: &'a mut decode::Decoder<R>,
}

impl<R: Read + Seek> Iterator for ApeSamples<'_, R> {
    type Item = Result<i32, ApeError>;

    fn next(&mut self) -> Option<Self::Item> {
        // Try to get a sample from the current output buffer
        if let Some(s) = self.decoder.next_sample() {
            return Some(Ok(s));
        }

        // Buffer exhausted — decode the next frame
        if self.decoder.finished {
            return None;
        }

        match self.decoder.decode_next_frame() {
            Ok(true) => self.decoder.next_sample().map(Ok),
            Ok(false) => None, // Stream ended
            Err(e) => Some(Err(e)),
        }
    }
}
