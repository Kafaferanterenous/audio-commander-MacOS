//! Frame decoder — orchestrates the APE decode pipeline.
//!
//! Per-frame pipeline:
//! 1. Seek to frame offset, read compressed data
//! 2. Initialize range coder from compressed data
//! 3. Range-decode residuals
//! 4. NNFilter inverse (add back short-term correlation)
//! 5. Predictor inverse (add back linear prediction)
//! 6. Channel decorrelation inverse (mid/side → L/R)
//! 7. Output interleaved PCM samples

use std::io::{Read, Seek, SeekFrom};

use crate::buffer::SampleBuffer;
use crate::error::ApeError;
use crate::header::ApeFileHeader;
use crate::nnfilter::NNFilter;
use crate::predictor::Predictor;
use crate::range_coder::{RangeCoder, RiceState};

/// Number of blocks decoded per inner loop iteration.
const BLOCKS_PER_LOOP: u32 = 4608;

/// Frame decoder state.
pub struct Decoder<R: Read + Seek> {
    pub reader: R,
    pub header: ApeFileHeader,
    /// Current frame index (0-based).
    current_frame: u32,
    /// Whether all frames have been decoded.
    pub finished: bool,
    /// Output sample buffer.
    pub buffer: SampleBuffer,
    /// NNFilter instances — one per channel.
    filters: Vec<NNFilter>,
    /// Predictor.
    predictor: Predictor,
    /// Compression level set index: (level / 1000) - 1.
    fset: usize,
}

impl<R: Read + Seek> Decoder<R> {
    /// Create a new decoder from a reader and parsed header.
    pub fn new(reader: R, header: ApeFileHeader) -> Self {
        let fset = (header.header.compression_level / 1000 - 1) as usize;
        let channels = header.header.channels as usize;

        // Create one NNFilter per channel
        let mut filters = Vec::with_capacity(channels);
        for _ in 0..channels {
            filters.push(NNFilter::new(fset));
        }

        Decoder {
            reader,
            header,
            current_frame: 0,
            finished: false,
            buffer: SampleBuffer::new(),
            filters,
            predictor: Predictor::new(),
            fset,
        }
    }

    /// Get the next buffered sample, if any.
    pub fn next_sample(&mut self) -> Option<i32> {
        self.buffer.next_sample()
    }

    /// Per-channel samples in a full frame.
    pub fn blocks_per_frame(&self) -> u32 {
        self.header.header.blocks_per_frame
    }

    /// Restart decoding at `frame`. Frames are independently decodable (the
    /// filter and predictor reset per frame), so no earlier state is needed and
    /// the next `decode_next_frame` reads straight from the seek table.
    pub fn seek_to_frame(&mut self, frame: u32) {
        let total = self.header.header.total_frames;
        self.current_frame = if frame > total { total } else { frame };
        self.finished = false;
        self.buffer.clear();
        for f in &mut self.filters {
            f.reset();
        }
        self.predictor.reset();
    }

    /// Decode the next frame, filling the sample buffer.
    /// Returns true if samples were decoded, false if stream ended.
    pub fn decode_next_frame(&mut self) -> Result<bool, ApeError> {
        if self.current_frame >= self.header.header.total_frames {
            self.finished = true;
            return Ok(false);
        }

        // How many blocks (samples per channel) in this frame?
        let nblocks = if self.current_frame == self.header.header.total_frames - 1 {
            self.header.header.final_frame_blocks
        } else {
            self.header.header.blocks_per_frame
        };

        if nblocks == 0 {
            self.finished = true;
            return Ok(false);
        }

        // Read compressed frame data
        let frame_data = self.read_frame_data()?;

        // Reset filter and predictor state for this frame
        for f in &mut self.filters {
            f.reset();
        }
        self.predictor.reset();
        self.buffer.clear();

        // Decode the frame
        let channels = self.header.header.channels;
        if channels == 1 {
            self.decode_frame_mono(&frame_data, nblocks)?;
        } else {
            self.decode_frame_stereo(&frame_data, nblocks)?;
        }

        self.current_frame += 1;
        Ok(true)
    }

    /// Read compressed data for the current frame.
    ///
    /// Reads from a 4-byte-aligned file position (matching FFmpeg's bswap_buf
    /// alignment) and byte-swaps each 4-byte group so the range coder sees
    /// bytes in the correct order.
    fn read_frame_data(&mut self) -> Result<Vec<u8>, ApeError> {
        let frame_idx = self.current_frame as usize;
        let seek_table = &self.header.seek_table;

        if frame_idx >= seek_table.len() {
            return Err(ApeError::InvalidSeekTable);
        }

        // Start at 4-byte aligned position (low 2 bits are alignment skip)
        let start = (seek_table[frame_idx] & !3) as u64;

        // End is either the next frame's offset or end of frame data.
        // Use total_frames (not seek_table.len()) — the seek table may be
        // pre-allocated to a maximum size with zero-filled trailing entries.
        let total_frames = self.header.header.total_frames as usize;
        let end = if frame_idx + 1 < total_frames {
            seek_table[frame_idx + 1] as u64
        } else {
            // Last frame: compute from total frame data size
            let total_data = self.header.descriptor.ape_frame_data_bytes as u64
                | ((self.header.descriptor.ape_frame_data_bytes_high as u64) << 32);
            self.header.data_offset + total_data
        };

        let size = (end - start) as usize;
        if size == 0 {
            return Err(ApeError::UnexpectedEof);
        }

        // Seek and read
        self.reader.seek(SeekFrom::Start(start))?;
        let mut data = vec![0u8; size];
        self.reader.read_exact(&mut data)?;

        // Byte-swap each 4-byte group (matching FFmpeg's bswap_buf).
        // APE stores data as little-endian 32-bit words; the range coder
        // expects the bytes in big-endian order within each word.
        let full_words = size / 4;
        for i in 0..full_words {
            let off = i * 4;
            data.swap(off, off + 3);
            data.swap(off + 1, off + 2);
        }

        Ok(data)
    }

    /// Skip the per-frame header: alignment bytes, CRC, optional frame flags, skip byte.
    /// Returns a slice pointing to the start of range-coded data.
    fn skip_frame_header<'a>(&self, frame_data: &'a [u8]) -> Result<&'a [u8], ApeError> {
        let mut pos = 0usize;

        // Skip byte-alignment padding (low 2 bits of seek table entry)
        let align_skip = (self.header.seek_table[self.current_frame as usize] & 3) as usize;
        pos += align_skip;

        if pos + 4 > frame_data.len() {
            return Err(ApeError::UnexpectedEof);
        }

        // Read 4-byte big-endian CRC
        let crc = u32::from_be_bytes([
            frame_data[pos],
            frame_data[pos + 1],
            frame_data[pos + 2],
            frame_data[pos + 3],
        ]);
        pos += 4;

        // If CRC has high bit set, next 4 bytes are frame flags
        if crc & 0x80000000 != 0 {
            if pos + 4 > frame_data.len() {
                return Err(ApeError::UnexpectedEof);
            }
            // frame flags — we don't use them yet but must skip
            pos += 4;
        }

        // Skip 1 byte (the first 8 bits of input are ignored by the range coder)
        if pos >= frame_data.len() {
            return Err(ApeError::UnexpectedEof);
        }
        pos += 1;

        Ok(&frame_data[pos..])
    }

    /// Decode a mono frame.
    fn decode_frame_mono(
        &mut self,
        frame_data: &[u8],
        nblocks: u32,
    ) -> Result<(), ApeError> {
        let data = self.skip_frame_header(frame_data)?;

        let mut rc = RangeCoder::new(data);
        let mut rice = RiceState::new();

        for _ in 0..nblocks {
            // 1. Range decode residual
            let residual = rc.decode_value(&mut rice);

            // 2. NNFilter inverse
            let filtered = self.filters[0].decompress(residual);

            // 3. Predictor inverse
            let sample = self.predictor.decode_mono(filtered);

            self.buffer.push(sample);
        }

        Ok(())
    }

    /// Decode a stereo frame.
    fn decode_frame_stereo(
        &mut self,
        frame_data: &[u8],
        nblocks: u32,
    ) -> Result<(), ApeError> {
        let data = self.skip_frame_header(frame_data)?;

        let mut rc = RangeCoder::new(data);
        let mut rice_y = RiceState::new();
        let mut rice_x = RiceState::new();

        for _ in 0..nblocks {
            // Decode Y channel (first in stereo)
            let residual_y = rc.decode_value(&mut rice_y);
            let filtered_y = self.filters[0].decompress(residual_y);

            // Decode X channel
            let residual_x = rc.decode_value(&mut rice_x);
            let filtered_x = self.filters[1].decompress(residual_x);

            // Predictor inverse + channel decorrelation
            let (left, right) = self.predictor.decode_stereo(filtered_y, filtered_x);

            self.buffer.push_stereo(left, right);
        }

        Ok(())
    }
}
