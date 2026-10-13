//! Minimal C ABI over the pure-Rust decoder, so the vendored `decoders.c`
//! (a plain C translation unit) can drive APE playback without knowing Rust.
//!
//! Everything is deliberately owned and heap-allocated on the Rust side: the
//! caller passes the whole compressed file once, then pulls interleaved PCM in
//! fixed-size blocks, seeks by absolute sample index, and finally closes the
//! handle. The decoder keeps no global state, so multiple handles are fine.

use std::io::Cursor;

use crate::ApeReader;

/// Opaque decoder handle handed back to C.
pub struct ApeHandle {
    reader: ApeReader<Cursor<Vec<u8>>>,
}

/// Stream description copied out for the C side.
#[repr(C)]
pub struct ApeInfoFfi {
    pub sample_rate: u32,
    pub channels: u32,
    pub bits_per_sample: u32,
    /// Per-channel sample frames (not interleaved samples).
    pub total_frames: u64,
    /// Per-channel samples in a full frame; how coarse a seek can land.
    pub blocks_per_frame: u32,
    pub compression_level: u32,
    pub format_version: u32,
}

/// Parse a whole APE file held in memory. Returns null on any error.
#[unsafe(no_mangle)]
pub extern "C" fn ape_open_file(data: *const u8, size: usize) -> *mut ApeHandle {
    if data.is_null() || size == 0 {
        return std::ptr::null_mut();
    }
    // Copy: the handle must stay valid after the C caller's buffer goes away.
    let bytes = unsafe { std::slice::from_raw_parts(data, size) }.to_vec();
    match ApeReader::new(Cursor::new(bytes)) {
        Ok(reader) => Box::into_raw(Box::new(ApeHandle { reader })),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Fill `out` with the stream description. Returns 1 on success.
#[unsafe(no_mangle)]
pub extern "C" fn ape_info(h: *const ApeHandle, out: *mut ApeInfoFfi) -> i32 {
    if h.is_null() || out.is_null() {
        return 0;
    }
    let handle = unsafe { &*h };
    let info = handle.reader.info();
    let out = unsafe { &mut *out };
    out.sample_rate = info.sample_rate;
    out.channels = info.channels as u32;
    out.bits_per_sample = info.bits_per_sample as u32;
    out.total_frames = handle.reader.total_blocks();
    out.blocks_per_frame = handle.reader.blocks_per_frame();
    out.compression_level = info.compression_level as u32;
    out.format_version = info.format_version as u32;
    1
}

/// Seek to an absolute per-channel sample index (clamped to the stream end).
/// The next `ape_read` returns exactly that sample. Returns 1 on success.
#[unsafe(no_mangle)]
pub extern "C" fn ape_seek(h: *mut ApeHandle, sample: u64) -> i32 {
    if h.is_null() {
        return 0;
    }
    let handle = unsafe { &mut *h };
    handle.reader.seek_sample(sample);
    1
}

/// Decode up to `max_frames` stereo/mono frames into `out` as interleaved i32
/// (native scale). Returns frames written, 0 at end of stream, or -1 on a
/// decode error.
#[unsafe(no_mangle)]
pub extern "C" fn ape_read(h: *mut ApeHandle, out: *mut i32, max_frames: usize) -> i64 {
    if h.is_null() || out.is_null() || max_frames == 0 {
        return 0;
    }
    let handle = unsafe { &mut *h };
    let channels = handle.reader.info().channels as usize;
    if channels == 0 {
        return 0;
    }
    let cap = max_frames * channels;
    let out_slice = unsafe { std::slice::from_raw_parts_mut(out, cap) };

    let mut written = 0usize;
    let mut samples = handle.reader.samples();
    while written < cap {
        match samples.next() {
            Some(Ok(s)) => {
                out_slice[written] = s;
                written += 1;
            }
            Some(Err(_)) => return -1,
            None => break,
        }
    }
    (written / channels) as i64
}

/// Release a handle created by `ape_open_file`. Null is accepted.
#[unsafe(no_mangle)]
pub extern "C" fn ape_close(h: *mut ApeHandle) {
    if !h.is_null() {
        unsafe { drop(Box::from_raw(h)) };
    }
}
