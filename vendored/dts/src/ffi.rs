//! Thin C shim over the vendored pure-Rust DTS decoder (oxideav-dts, MIT).
//!
//! `vendored/decoders/decoders.c` includes `dts_ffi.h`; the symbols come
//! from the `oxideav_dts` static library that `build.sh` and
//! `tools/build_tools.sh` produce. The contract mirrors the ape-rs shim:
//!
//! * `dts_open` **borrows** the caller's byte buffer for the handle's
//!   lifetime (the caller keeps it alive until `dts_close`, exactly like
//!   `ape_open_file`).
//! * Frames are indexed once at open (offset + container length + native
//!   sample count per frame), which gives duration, sample-accurate seek
//!   and per-frame decode without re-scanning.
//! * `dts_read` hands back **interleaved** int32 PCM at the stream's
//!   native rate: the primary planes in DTS transmission order, plus the
//!   interpolated LFE plane trailing (when the stream carries LFE), so the
//!   width is `info.channels + info.has_lfe` and stays constant for the
//!   whole stream.
//! * The §C.2.5 synthesis filter tail carries across frames
//!   (`CoreStreamDecoder`); a seek reconstructs a fresh stream decoder
//!   (one filter warm-up transient at the seek point, same trade-off the
//!   APE path makes).

#![allow(unsafe_code)]

use crate::{
    decode_audio_coding_header_at, find_next_sync, parse_frame_header, parse_frame_header_14bit,
    unpack_14bit_to_16bit, CoreStreamDecoder, DtsFrameHeader, FourteenBitByteOrder,
    SyncWordEncoding,
};
use std::os::raw::{c_int, c_void};

/// Samples a normal Core frame produces per plane: `(NBLKS + 1) * 32`
/// (ETSI TS 102 114 §C.2; the crate documents the frame total as always
/// `(NBLKS + 1) * 32`). Termination frames carry a short trailing
/// subsubframe, so duration treats their contribution as this nominal
/// count — the overstatement is under one frame (≤ ~10 ms).
const SAMPLES_PER_BLOCK: u32 = 32;

/// Stream facts for the C side (`DtsInfoFfi` in `dts_ffi.h`).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct DtsInfoFfi {
    /// Native sample rate in Hz (e.g. 48000).
    pub sample_rate: u32,
    /// Primary audio planes (DTS transmission order).
    pub channels: u32,
    /// `1` when an interpolated LFE plane trails the primary planes.
    pub has_lfe: u32,
    /// Raw AMODE channel-configuration code from the frame header.
    pub amode: u32,
    /// Per-plane samples `dts_read` will produce before end of stream.
    pub total_samples: u64,
}

/// One indexed frame's location and nominal contribution.
#[derive(Clone, Copy)]
struct FrameEnt {
    /// Byte offset of the frame's sync within the container.
    offset: u64,
    /// Container bytes to advance to the next frame.
    len: u32,
    /// Nominal native samples for this frame (`(NBLKS + 1) * 32`).
    samples: u32,
}

struct DtsHandle {
    /// Borrowed for the whole handle lifetime (caller contract).
    data: *const u8,
    size: usize,
    frames: Vec<FrameEnt>,
    /// Per-plane samples (frame-0 measured + nominal middle +
    /// last-frame measured when decodable).
    total_samples: u64,
    rate: u32,
    channels: u32,
    has_lfe: u32,
    amode: u32,
    /// Next frame index to decode.
    cur: usize,
    /// Samples still to drop after a seek (per plane).
    skip: u64,
    /// Sticky end-of-stream (decode error or frame exhaustion).
    eof: bool,
    stream: Option<CoreStreamDecoder>,
    /// Current frame's planar PCM (primary planes + optional LFE last).
    planes: Vec<Vec<i32>>,
    /// Sample cursor inside `planes`.
    pos: usize,
    /// Sample length of the current frame (planes all equal length).
    plane_len: usize,
}

/// Parse one frame header at the start of `bytes`, routing the two
/// 14-bit container encodings to the 14-bit entry point.
fn parse_at(bytes: &[u8]) -> Option<DtsFrameHeader> {
    match parse_frame_header(bytes) {
        Ok(h) => Some(h),
        Err(crate::Error::UnsupportedFourteenBit) => parse_frame_header_14bit(bytes).ok(),
        Err(_) => None,
    }
}

/// Convert a container frame slice into the raw-big-endian 16-bit domain
/// `decode_core_frame` operates on, mirroring the registry's
/// `send_packet` (raw-BE pass-through, raw-LE word swap, 14-bit unpack).
fn prepare_frame(slice: &[u8]) -> Option<(Vec<u8>, DtsFrameHeader)> {
    let enc = find_next_sync(slice, 0)?;
    if enc.offset != 0 {
        return None;
    }
    match enc.encoding {
        SyncWordEncoding::RawBigEndian => {
            let hdr = parse_frame_header(slice).ok()?;
            Some((slice.to_vec(), hdr))
        }
        SyncWordEncoding::RawLittleEndian => {
            let mut swapped = slice.to_vec();
            for pair in swapped.chunks_exact_mut(2) {
                pair.swap(0, 1);
            }
            let hdr = parse_frame_header(&swapped).ok()?;
            Some((swapped, hdr))
        }
        SyncWordEncoding::FourteenBitBigEndian
        | SyncWordEncoding::FourteenBitLittleEndian => {
            let order = FourteenBitByteOrder::from_sync(enc.encoding)?;
            let unpacked = unpack_14bit_to_16bit(slice, order).ok()?;
            let hdr = parse_frame_header(&unpacked).ok()?;
            Some((unpacked, hdr))
        }
    }
}

/// Nominal native samples for a parsed frame header.
fn nominal_samples(hdr: &DtsFrameHeader) -> u32 {
    (hdr.blocks_per_frame as u32 + 1) * SAMPLES_PER_BLOCK
}

impl DtsHandle {
    /// Decode `idx` into `self.planes`, carrying the §C.2.5 filter tail
    /// from the previous frame. Returns `false` on end of stream or a
    /// decode failure (sticky).
    fn decode_next(&mut self) -> bool {
        if self.eof || self.cur >= self.frames.len() {
            self.eof = true;
            return false;
        }
        let ent = self.frames[self.cur];
        let off = ent.offset as usize;
        let len = ent.len as usize;
        if off > self.size || len == 0 || off + len > self.size {
            self.eof = true;
            return false;
        }
        let slice = unsafe { std::slice::from_raw_parts(self.data.add(off), len) };
        let prepared = match prepare_frame(slice) {
            Some((bytes, hdr)) => (bytes, hdr),
            None => {
                self.eof = true;
                return false;
            }
        };
        let (bytes, hdr) = prepared;
        let stream = self.stream.get_or_insert_with(|| {
            CoreStreamDecoder::new(self.channels as usize)
        });
        match stream.decode_frame(&bytes, &hdr) {
            Ok(mut pcm) => {
                let mut lfe = stream.take_last_lfe_pcm();
                let primary_len = pcm.first().map(Vec::len).unwrap_or(0);
                if pcm.len() != self.channels as usize || primary_len == 0 {
                    self.eof = true;
                    return false;
                }
                if self.has_lfe == 1 {
                    // Width must stay constant: pad a missing/short LFE
                    // plane with silence (LFF may vary per frame).
                    lfe.resize(primary_len, 0);
                    pcm.push(lfe);
                }
                self.plane_len = primary_len;
                self.planes = pcm;
                self.pos = 0;
                self.cur += 1;
                // Drop samples a seek asked for; they may exceed the
                // measured length of a short (termination) frame, in
                // which case the drop simply continues into the next
                // frame or lands on end of stream.
                while self.skip > 0 {
                    if (self.skip as usize) >= self.plane_len {
                        self.skip -= self.plane_len as u64;
                        self.pos = self.plane_len;
                        if self.skip > 0 && !self.decode_next_skip_tail() {
                            return false;
                        }
                        return true;
                    } else {
                        self.pos = self.skip as usize;
                        self.skip = 0;
                    }
                }
                true
            }
            Err(_) => {
                self.eof = true;
                false
            }
        }
    }

    /// Continue a seek's sample drop across a frame boundary without
    /// re-entering the drop loop at the call site.
    fn decode_next_skip_tail(&mut self) -> bool {
        // decode_next() re-applies any remaining `skip` itself.
        if self.cur >= self.frames.len() {
            self.eof = true;
            return false;
        }
        self.decode_next()
    }
}

/// One-byte-first sniff: does a parseable DTS Core frame header start at
/// offset zero? Used by `dec_open` to gate before probing tracker modules.
#[no_mangle]
pub extern "C" fn dts_sniff(data: *const u8, size: usize) -> c_int {
    if data.is_null() || size < 16 {
        return 0;
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, size) };
    if parse_at(bytes).is_some() {
        1
    } else {
        0
    }
}

/// Open a raw DTS Core elementary stream (`.dts` / `.dtshd`), borrowing
/// `data` until `dts_close`. Returns `NULL` when the stream has no
/// parseable frame at offset zero or the first frame will not decode.
#[no_mangle]
pub extern "C" fn dts_open(data: *const u8, size: usize) -> *mut c_void {
    if data.is_null() || size < 16 {
        return std::ptr::null_mut();
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, size) };

    // Index every frame: offset + container advance + nominal samples.
    // Stops at the first frame that will not parse or overruns the
    // buffer (a truncated tail is simply not indexed), or right after a
    // termination frame.
    let mut frames: Vec<FrameEnt> = Vec::new();
    let mut cursor: usize = 0;
    while cursor < bytes.len() {
        let rest = &bytes[cursor..];
        let hdr = match parse_at(rest) {
            Some(h) => h,
            None => break,
        };
        let advance = hdr.frame_size_container_bytes(hdr.sync_word_encoding) as usize;
        if advance == 0 || cursor + advance > bytes.len() {
            break;
        }
        let samples = nominal_samples(&hdr);
        frames.push(FrameEnt {
            offset: cursor as u64,
            len: advance as u32,
            samples,
        });
        cursor += advance;
        if hdr.frame_type == crate::FrameType::Termination {
            break;
        }
    }
    if frames.is_empty() {
        return std::ptr::null_mut();
    }

    // Frame 0 fully: learns the primary plane count, the LFE presence,
    // rate and AMODE, and validates the decode chain end to end. Its
    // PCM becomes the first readable frame so playback starts at sample
    // zero with the filter tail already warm.
    let f0 = frames[0];
    let (bytes0, hdr0) = match prepare_frame(&bytes[f0.offset as usize..][..f0.len as usize]) {
        Some(v) => v,
        None => return std::ptr::null_mut(),
    };
    let rate = match hdr0.sample_rate_hz() {
        Some(r) if r > 0 => r,
        _ => return std::ptr::null_mut(),
    };
    let (coding, _) = match decode_audio_coding_header_at(
        &bytes0,
        hdr0.header_bit_length() as usize,
        hdr0.crc_present,
    ) {
        Ok(v) => v,
        Err(_) => return std::ptr::null_mut(),
    };
    let channels = coding.n_pchs;
    if channels == 0 || channels > 8 {
        return std::ptr::null_mut();
    }
    let mut stream = CoreStreamDecoder::new(channels);
    let pcm0 = match stream.decode_frame(&bytes0, &hdr0) {
        Ok(p) => p,
        Err(_) => return std::ptr::null_mut(),
    };
    let lfe0 = stream.take_last_lfe_pcm();
    let measured0 = pcm0.first().map(Vec::len).unwrap_or(0);
    if measured0 == 0 || pcm0.len() != channels {
        return std::ptr::null_mut();
    }
    let has_lfe = if !lfe0.is_empty() && lfe0.len() == measured0 {
        1
    } else {
        0
    };

    // Measure the last frame too when it is distinct from frame 0, so
    // duration is exact for streams that end in a short termination
    // frame. Fall back to the nominal count when it will not decode.
    let last = frames.len() - 1;
    let total_samples = if last == 0 {
        measured0 as u64
    } else {
        let middle: u64 = frames[1..last].iter().map(|f| f.samples as u64).sum();
        let f_last = frames[last];
        let measured_last = {
            let mut probe = CoreStreamDecoder::new(channels);
            let mut measured: Option<u64> = None;
            if let Some((b, h)) = prepare_frame(
                &bytes[f_last.offset as usize..][..f_last.len as usize],
            ) {
                if let Ok(p) = probe.decode_frame(&b, &h) {
                    measured = p.first().map(|v| v.len() as u64);
                }
            }
            measured.unwrap_or(f_last.samples as u64)
        };
        measured0 as u64 + middle + measured_last
    };

    // Keep frame 0's decoded planes as the first readable frame.
    let mut planes0 = pcm0;
    if has_lfe == 1 {
        let mut lfe0 = lfe0;
        lfe0.resize(measured0, 0);
        planes0.push(lfe0);
    }

    let handle = DtsHandle {
        data,
        size,
        frames,
        total_samples,
        rate,
        channels: channels as u32,
        has_lfe,
        amode: hdr0.amode as u32,
        cur: 1,
        skip: 0,
        eof: false,
        stream: Some(stream),
        planes: planes0,
        pos: 0,
        plane_len: measured0,
    };
    Box::into_raw(Box::new(handle)) as *mut c_void
}

/// Fill `out` with the stream facts. Returns `1` on success.
///
/// # Safety
/// `h` must be a handle from `dts_open`; `out` must be valid for one
/// `DtsInfoFfi`.
#[no_mangle]
pub extern "C" fn dts_info(h: *const c_void, out: *mut DtsInfoFfi) -> c_int {
    if h.is_null() || out.is_null() {
        return 0;
    }
    let d = unsafe { &*(h as *const DtsHandle) };
    unsafe {
        *out = DtsInfoFfi {
            sample_rate: d.rate,
            channels: d.channels,
            has_lfe: d.has_lfe,
            amode: d.amode,
            total_samples: d.total_samples,
        };
    }
    1
}

/// Reposition to `sample` (per-plane, native rate). Returns `1` on
/// success, `0` for an invalid handle. A target at/past the end is
/// accepted and lands on end of stream.
///
/// # Safety
/// `h` must be a handle from `dts_open`.
#[no_mangle]
pub extern "C" fn dts_seek(h: *mut c_void, sample: u64) -> c_int {
    if h.is_null() {
        return 0;
    }
    let d = unsafe { &mut *(h as *mut DtsHandle) };
    d.planes.clear();
    d.pos = 0;
    d.plane_len = 0;
    d.skip = 0;
    d.eof = false;
    d.stream = Some(CoreStreamDecoder::new(d.channels as usize));
    if sample >= d.total_samples {
        d.cur = d.frames.len();
        return 1;
    }
    // Frame containing the target: first i with prefix(i+1) > sample.
    let mut acc: u64 = 0;
    let mut idx = d.frames.len();
    for (i, f) in d.frames.iter().enumerate() {
        if acc + f.samples as u64 > sample {
            idx = i;
            break;
        }
        acc += f.samples as u64;
    }
    if idx >= d.frames.len() {
        d.cur = d.frames.len();
        return 1;
    }
    d.cur = idx;
    d.skip = sample - acc;
    1
}

/// Decode up to `max_frames` interleaved frames into `out`
/// (`channels + has_lfe` int32 samples per frame, transmission order
/// with LFE trailing). Returns frames written; `0` = end of stream.
///
/// # Safety
/// `h` must be a handle from `dts_open`; `out` must be valid for
/// `(channels + has_lfe) * max_frames` int32 values.
#[no_mangle]
pub extern "C" fn dts_read(h: *mut c_void, out: *mut i32, max_frames: i64) -> i64 {
    if h.is_null() || out.is_null() || max_frames <= 0 {
        return 0;
    }
    let d = unsafe { &mut *(h as *mut DtsHandle) };
    let width = (d.channels + d.has_lfe) as usize;
    if width == 0 {
        return 0;
    }
    let out = unsafe { std::slice::from_raw_parts_mut(out, (max_frames as usize) * width) };
    let mut written: i64 = 0;
    while (written as i64) < max_frames {
        if d.pos >= d.plane_len {
            if !d.decode_next() {
                break;
            }
            if d.pos >= d.plane_len {
                // Frame decoded but fully dropped by the seek cursor.
                continue;
            }
        }
        let avail = d.plane_len - d.pos;
        let room = (max_frames - written) as usize;
        let n = if avail < room { avail } else { room };
        let base = written as usize * width;
        for f in 0..n {
            let src = d.pos + f;
            let dst = base + f * width;
            for (c, plane) in d.planes.iter().enumerate() {
                out[dst + c] = plane[src];
            }
        }
        d.pos += n;
        written += n as i64;
    }
    written
}

/// Release a handle from `dts_open`. Safe on `NULL`.
///
/// # Safety
/// `h` must be a handle from `dts_open` (or `NULL`), not used afterwards.
#[no_mangle]
pub extern "C" fn dts_close(h: *mut c_void) {
    if h.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(h as *mut DtsHandle) });
}
