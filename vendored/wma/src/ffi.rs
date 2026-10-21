//! Thin C shim over the vendored pure-Rust WMA decoder (oxideav-wma, MIT).
//!
//! `vendored/decoders/decoders.c` includes `wma_ffi.h`; the symbols come
//! from the `oxideav_wma` static library that `build.sh` and
//! `tools/build_tools.sh` produce. The contract mirrors the ape-rs/dts
//! shims:
//!
//! * `wma_open` **borrows** the caller's byte buffer for the handle's
//!   lifetime (the caller keeps it alive until `wma_close`).
//! * `wma_open` parses the ASF container (the crate itself covers only
//!   the codec payload), extracts the audio stream's `WAVEFORMATEX`
//!   extradata, and walks the Data Object into the stream's
//!   `block_align`-sized media objects.
//! * The codec is driven through the crate's own direct chain —
//!   `StreamConfig` → `PacketAssembler` → `FrameParser` → `BlockSynth` —
//!   the exact sequence the crate's `registration` module uses (that
//!   module is not vendored; the optional `oxideav-core` dependency it
//!   would pull is deliberately omitted).
//! * `wma_read` hands back **interleaved** int32 PCM at the stream's
//!   declared sample rate, mono duplicated to stereo so the C side sees
//!   a constant `channels = 2` width.
//!
//! ## ASF
//!
//! Minimal ASF reader for the WMA case: the Header Object's Stream
//! Properties Object (GUID `…-00-00`) carrying stream type Audio
//! (`f8699e40-5b4d-11cf-a8fd-00805f5c442b`) and its `WAVEFORMATEX`,
//! then the Data Object's packets. Each ASF packet has a fixed header
//! (with optional error correction and payload parsing information)
//! followed by single- or multiple-payload media objects; the WMA
//! codec payloads concatenated are exactly the `block_align`-sized
//! packets the decoder consumes.

#![allow(unsafe_code)]

use std::os::raw::{c_int, c_void};

use crate::header::{Version, WmaHeader};
use crate::packet::PacketAssembler;
use crate::stream_config::StreamConfig;
use crate::vendor_decode::BlockSynth;
use crate::vendor_frame::FrameParser;

/// Stream facts for the C side (`wma_info_t` in `wma_ffi.h`).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct WmaInfoFfi {
    /// Native sample rate in Hz (e.g. 44100).
    pub sample_rate: u32,
    /// Channel count (1 or 2).
    pub channels: u32,
    /// Codec version: 1 or 2.
    pub version: u32,
    /// Per-channel samples `wma_read` will produce before end of stream.
    pub total_samples: u64,
}

/// Errors surfaced to C as a NULL handle / -1.
enum OpenError {
    NoAudioStream,
    BadConfig,
    Decode,
}

struct WmaHandle {
    cfg: StreamConfig,
    /// The `block_align`-sized codec packets, in container order.
    packets: Vec<Vec<u8>>,
    /// Decoded interleaved-stereo i32 PCM at the stream's native rate.
    /// Assembled lazily as packets are consumed; `read_pos` is the
    /// frame cursor into `pcm`.
    pcm: Vec<i32>,
    read_pos: usize,
    channels: usize,
    sample_rate: u32,
    version: u32,
}

// ---------------------------------------------------------------------------
// ASF parsing
// ---------------------------------------------------------------------------

/// ASF Header Object GUID (`75B22630-668E-11CF-A6D9-00AA0062CE6C`).
const ASF_HEADER_GUID: [u8; 16] = [
    0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
];
/// ASF Data Object GUID (`75B22636-668E-11CF-A6D9-00AA0062CE6C`).
const ASF_DATA_GUID: [u8; 16] = [
    0x36, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
];
/// Stream Properties Object GUID (`B7DC0791-A9B7-11CF-8EE6-00C00C205365`).
const ASF_STREAM_PROPERTIES_GUID: [u8; 16] = [
    0x91, 0x07, 0xDC, 0xB7, 0xB7, 0xA9, 0xCF, 0x11, 0x8E, 0xE6, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65,
];
/// Audio media type GUID (`F8699E40-5B4D-11CF-A8FD-00805F5C442B`).
const ASF_AUDIO_MEDIA_GUID: [u8; 16] = [
    0x40, 0x9E, 0x69, 0xF8, 0x4D, 0x5B, 0xCF, 0x11, 0xA8, 0xFD, 0x00, 0x80, 0x5F, 0x5C, 0x44, 0x2B,
];

fn guid_eq(a: &[u8], b: &[u8; 16]) -> bool {
    a.len() >= 16 && &a[..16] == b
}

fn rd_u16(b: &[u8], o: usize) -> Option<u16> {
    b.get(o..o + 2)
        .map(|s| u16::from_le_bytes([s[0], s[1]]))
}
fn rd_u32(b: &[u8], o: usize) -> Option<u32> {
    b.get(o..o + 4)
        .map(|s| u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
}
fn rd_u64(b: &[u8], o: usize) -> Option<u64> {
    b.get(o..o + 8)
        .map(|s| u64::from_le_bytes([s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7]]))
}

/// The audio stream description pulled from an ASF Stream Properties
/// Object.
struct AsfAudio {
    sample_rate: u32,
    channels: u16,
    avg_bytes_per_sec: u32,
    block_align: u16,
    codec_tag: u16,
    /// The `WAVEFORMATEX` extension bytes (`cbSize` worth).
    extradata: Vec<u8>,
}

/// Parse the ASF Header Object: locate the first audio Stream
/// Properties Object and return its WAVEFORMATEX description.
fn parse_asf_header(data: &[u8]) -> Option<AsfAudio> {
    if data.len() < 30 || !guid_eq(data, &ASF_HEADER_GUID) {
        return None;
    }
    // The header-size field is legitimately zero on some streamed files,
    // so the object walk is driven by the object count and bounded by
    // the file length, not by that field.
    let count = rd_u32(data, 24)? as usize;
    let mut off = 30usize; // 16 guid + 8 size + 4 count + 1 + 1 reserved
    let mut found: Option<AsfAudio> = None;
    for _ in 0..count {
        if off + 24 > data.len() {
            break;
        }
        let obj_guid = &data[off..off + 16];
        let obj_size = rd_u64(data, off + 16)? as usize;
        if obj_size < 24 || off + obj_size > data.len() {
            break;
        }
        if guid_eq(obj_guid, &ASF_STREAM_PROPERTIES_GUID) {
            // Within the object: stream type GUID (16), error-correction
            // GUID (16), time offset (8), type-specific data length (4),
            // error-correction data length (4), flags (2), reserved (4),
            // then the type-specific data (the WAVEFORMATEX).
            let p = off + 24;
            let media_guid = data.get(p..p + 16)?;
            let tsd_len = rd_u32(data, p + 40)? as usize;
            let tsd = p + 54;
            if guid_eq(media_guid, &ASF_AUDIO_MEDIA_GUID) && found.is_none() {
                if let Some(a) = parse_waveformatex(data, tsd, tsd_len) {
                    if a.codec_tag == 0x0160 || a.codec_tag == 0x0161 {
                        found = Some(a);
                    }
                }
            }
        }
        off += obj_size;
    }
    found
}

/// Parse a `WAVEFORMATEX` (+ trailing extension) at `off`.
fn parse_waveformatex(data: &[u8], off: usize, len: usize) -> Option<AsfAudio> {
    if len < 18 {
        return None;
    }
    let codec_tag = rd_u16(data, off)?;
    let channels = rd_u16(data, off + 2)?;
    let sample_rate = rd_u32(data, off + 4)?;
    let avg_bytes_per_sec = rd_u32(data, off + 8)?;
    let block_align = rd_u16(data, off + 12)?;
    let cb_size = rd_u16(data, off + 16)? as usize;
    let mut extradata = Vec::new();
    if cb_size > 0 && off + 18 + cb_size <= data.len() {
        extradata.extend_from_slice(&data[off + 18..off + 18 + cb_size]);
    }
    Some(AsfAudio {
        sample_rate,
        channels,
        avg_bytes_per_sec,
        block_align,
        codec_tag,
        extradata,
    })
}

/// Parse the ASF Data Object into the concatenated codec-payload packets,
/// then split on `block_align`.
fn parse_asf_packets(data: &[u8], block_align: u16, packet_size: u32) -> Vec<Vec<u8>> {
    let mut out: Vec<u8> = Vec::new();
    // The Data Object follows the Header Object; locate its GUID.
    let data_obj = match find_guid(data, &ASF_DATA_GUID) {
        Some(o) => o,
        None => return Vec::new(),
    };
    let data_size = rd_u64(data, data_obj + 16).unwrap_or(0) as usize;
    // Data Object: 24-byte object header + 16-byte file-id + 8-byte
    // total-packets + 2-byte reserved = the packet region follows at +50.
    let packet_region_start = data_obj + 50;
    let end = if data_size == 0 {
        data.len()
    } else {
        (data_obj + 24 + data_size).min(data.len())
    };
    let psize = packet_size as usize;
    if psize < 50 {
        return Vec::new();
    }
    let mut off = packet_region_start;
    while off + psize <= end {
        if let Some(payload) = extract_asf_packet_payload(&data[off..off + psize]) {
            out.extend_from_slice(&payload);
        }
        off += psize;
    }
    let ba = block_align as usize;
    if ba == 0 {
        return Vec::new();
    }
    out.chunks_exact(ba).map(|c| c.to_vec()).collect()
}

/// Find the first occurrence of a 16-byte GUID in `data`.
fn find_guid(data: &[u8], guid: &[u8; 16]) -> Option<usize> {
    data.windows(16).position(|w| w == guid)
}

/// Extract the media-object payload bytes from one fixed-size ASF packet.
///
/// Follows the ASF data-packet layout ([ASF] §5.2): an error-correction
/// structure (when present), then the payload-parsing-information
/// (length-type flags, property flags, packet length, sequence, padding
/// length, send time, duration), then per-payload headers and payloads.
fn extract_asf_packet_payload(pkt: &[u8]) -> Option<Vec<u8>> {
    let n = pkt.len();
    if n < 12 {
        return None;
    }
    // ---- Error Correction structure (§5.2.1) ----
    // The first byte's bit 7 signals EC presence; bits 0-3 hold the EC
    // data length in bytes (bits 5-6, the length type, are 0 in every
    // real file so the low nibble is the size).
    let ec_first = pkt[0];
    let mut off = 1usize;
    if ec_first & 0x80 != 0 {
        let ec_data_len = (ec_first & 0x0F) as usize;
        off += ec_data_len;
    }
    if off >= n {
        return None;
    }

    // ---- Payload parsing information (§5.2.2) ----
    let lt = pkt[off];
    off += 1;
    let multiple = (lt & 0x01) != 0;
    let seq_type = (lt >> 1) & 0x03;
    let pad_type = (lt >> 3) & 0x03;
    let plen_type = (lt >> 5) & 0x03;
    let _ec_present = (lt & 0x80) != 0;

    if off >= n {
        return None;
    }
    let pf = pkt[off];
    off += 1;
    let repl_type = pf & 0x03;
    let offset_type = (pf >> 2) & 0x03;
    let objnum_type = (pf >> 4) & 0x03;
    let strnum_type = (pf >> 6) & 0x03;

    let field_bytes = |t: u8| -> usize {
        match t {
            0 => 0,
            1 => 1,
            2 => 2,
            _ => 4,
        }
    };

    // Packet length
    off += field_bytes(plen_type);
    // Sequence
    off += field_bytes(seq_type);
    // Padding length
    off += field_bytes(pad_type);
    // Send time (DWORD) + duration (WORD)
    off += 4 + 2;
    if off > n {
        return None;
    }

    // Padding length was read above; recover it for payload trimming.
    let mut out: Vec<u8> = Vec::new();
    if !multiple {
        // Single payload: a payload header of stream number, media-object
        // number, offset and replicated-data length (each sized by the
        // property flags), then the replicated data, then the payload.
        off += field_bytes(strnum_type);
        off += field_bytes(objnum_type);
        off += field_bytes(offset_type);
        let repl_len = match repl_type {
            0 => 0usize,
            1 => *pkt.get(off).unwrap_or(&0) as usize,
            2 => rd_u16(pkt, off).unwrap_or(0) as usize,
            _ => rd_u32(pkt, off).unwrap_or(0) as usize,
        };
        off += field_bytes(repl_type);
        // Replicated data (media-object size + presentation time + …).
        off += repl_len;
        if off > n {
            return None;
        }
        out.extend_from_slice(&pkt[off..]);
        return Some(out);
    }

    // Multiple payloads (§5.2.3.3): a Payload Flags byte (number of
    // payloads in bits 0-5, payload-length type in bits 6-7), then each
    // payload's header + a Payload Length field + the payload data.
    if off >= n {
        return None;
    }
    let payload_flags = pkt[off];
    off += 1;
    let num_payloads = (payload_flags & 0x3F) as usize;
    let plen_field = ((payload_flags >> 6) & 0x03) as u8;
    let plen_bytes = field_bytes(plen_field);
    for _ in 0..num_payloads {
        // Stream number + media-object number + offset + replicated-data
        // length, each sized by the property flags.
        off += field_bytes(strnum_type);
        off += field_bytes(objnum_type);
        off += field_bytes(offset_type);
        let repl_len = match repl_type {
            0 => 0usize,
            1 => *pkt.get(off).unwrap_or(&0) as usize,
            2 => rd_u16(pkt, off).unwrap_or(0) as usize,
            _ => rd_u32(pkt, off).unwrap_or(0) as usize,
        };
        off += field_bytes(repl_type);
        off += repl_len;
        // Payload Length, then the payload data.
        let dlen = match plen_bytes {
            1 => *pkt.get(off).unwrap_or(&0) as usize,
            2 => rd_u16(pkt, off).unwrap_or(0) as usize,
            4 => rd_u32(pkt, off).unwrap_or(0) as usize,
            _ => 0,
        };
        let plen = plen_bytes.max(1);
        off += plen;
        if dlen == 0 || off + dlen > n {
            break;
        }
        out.extend_from_slice(&pkt[off..off + dlen]);
        off += dlen;
    }
    Some(out)
}

// ---------------------------------------------------------------------------
// Handle lifetime
// ---------------------------------------------------------------------------

fn open_internal(data: &[u8]) -> Result<WmaHandle, OpenError> {
    let audio = parse_asf_header(data).ok_or(OpenError::NoAudioStream)?;
    let version = Version::from_codec_id(audio.codec_tag).ok_or(OpenError::NoAudioStream)?;
    let channels = audio.channels.clamp(1, 2) as u8;
    // The ASF packet size lives in the File Properties Object
    // (min/max packet size); we read it from the Data-Object walk, but
    // the simplest robust choice is the stream's own packet size. WMA
    // files carry one media object per ASF packet sized `block_align`
    // *frames_per_packet*, so we derive the ASF packet size from the
    // Data Object header instead (below).
    let packet_size = read_asf_packet_size(data).unwrap_or(0);
    let header = WmaHeader::parse(
        version,
        audio.sample_rate,
        channels,
        audio.avg_bytes_per_sec.saturating_mul(8),
        audio.block_align,
        &audio.extradata,
    )
    .map_err(|_| OpenError::BadConfig)?;
    let cfg = StreamConfig::derive(
        version,
        header.sample_rate,
        channels,
        audio.avg_bytes_per_sec,
        audio.block_align,
        header.flags2,
    )
    .map_err(|_| OpenError::BadConfig)?;
    let packets = parse_asf_packets(data, audio.block_align, packet_size);
    if packets.is_empty() {
        return Err(OpenError::Decode);
    }
    Ok(WmaHandle {
        cfg,
        packets,
        pcm: Vec::new(),
        read_pos: 0,
        channels: channels as usize,
        sample_rate: header.sample_rate,
        version: match version {
            Version::V1 => 1,
            Version::V2 => 2,
        },
    })
}

/// Read the ASF File Properties Object's maximum packet size. It is the
/// 8-byte little-endian field at offset 92 within the File Properties
/// Object (GUID `8CABDCA1-A947-11CF-8EE4-00C00C205365`).
fn read_asf_packet_size(data: &[u8]) -> Option<u32> {
    const FILE_PROPERTIES_GUID: [u8; 16] = [
        0xA1, 0xDC, 0xAB, 0x8C, 0x47, 0xA9, 0xCF, 0x11, 0x8E, 0xE4, 0x00, 0xC0, 0x0C, 0x20, 0x53,
        0x65,
    ];
    if data.len() < 30 || !guid_eq(data, &ASF_HEADER_GUID) {
        return None;
    }
    let count = rd_u32(data, 24)? as usize;
    let mut off = 30usize;
    for _ in 0..count {
        if off + 24 > data.len() {
            break;
        }
        let obj_size = rd_u64(data, off + 16)? as usize;
        if obj_size < 24 || off + obj_size > data.len() {
            break;
        }
        if guid_eq(&data[off..off + 16], &FILE_PROPERTIES_GUID) {
            // Object header (24) then: file-id(16), file-size(8),
            // creation(8), packet-count(8), play-duration(8),
            // send-duration(8), preroll(8), flags(4), min-packet(4),
            // max-packet(4). max-packet is at +24+72 = +96.
            return rd_u32(data, off + 96);
        }
        off += obj_size;
    }
    None
}

impl WmaHandle {
    /// Decode all packets into `pcm` (interleaved stereo i32 at the
    /// native rate). Ran once, lazily, on the first read.
    fn decode_all(&mut self) {
        let mut asm = PacketAssembler::new(&self.cfg);
        let mut parser = FrameParser::new(&self.cfg, &[]);
        let mut synth = BlockSynth::new(&self.cfg);
        let mut out: Vec<Vec<f64>> = vec![Vec::new(); self.channels];
        let frame_len = usize::from(self.cfg.frame_length);
        let mut cursor: u64 = 0;
        let mut clean_pad = false;

        for pkt in &self.packets {
            let rec = match asm.push_packet(pkt) {
                Ok(r) => r,
                Err(_) => continue,
            };
            let k = asm.packets().len() - 1;
            parser.note_body_start(rec.body_start_bit);
            if k == 0 {
                cursor = asm.packets()[0].frames_start_bit();
            }
            // Decode every packet whose successor has arrived (the §1
            // reservoir carry lets a frame end inside the next packet).
            while asm.packets().len() > 1 && k >= 1 {
                let dec = k - 1;
                decode_one(
                    &asm, &mut parser, &mut synth, dec, &mut out, frame_len, false, &mut cursor,
                    &mut clean_pad,
                );
                break;
            }
        }
        // Flush the final packet + synthesis tail.
        let n = asm.packets().len();
        if n > 0 {
            decode_one(
                &asm,
                &mut parser,
                &mut synth,
                n - 1,
                &mut out,
                frame_len,
                true,
                &mut cursor,
                &mut clean_pad,
            );
        }
        let tail = synth.flush();
        for (ch, chan) in tail.into_iter().enumerate() {
            if ch < out.len() {
                out[ch].extend_from_slice(&chan);
            }
        }

        let samples = out.first().map_or(0, |c| c.len());
        let ch = self.channels;
        self.pcm.reserve(samples * 2);
        for t in 0..samples {
            let l = out[0][t];
            let r = if ch > 1 { out[1][t] } else { l };
            self.pcm.push(f2i(l));
            self.pcm.push(f2i(r));
        }
    }
}

/// Decode one packet's frames into `out`, mirroring the crate's
/// `registration::decode_packet` (padding resync, timeline-preserving
/// silence on parse failure, carry-boundary bookkeeping).
#[allow(clippy::too_many_arguments)]
fn decode_one(
    asm: &PacketAssembler,
    parser: &mut FrameParser,
    synth: &mut BlockSynth,
    k: usize,
    out: &mut [Vec<f64>],
    frame_len: usize,
    last: bool,
    cursor: &mut u64,
    clean_pad: &mut bool,
) {
    let rec = asm.packets()[k];
    if *cursor != rec.frames_start_bit() {
        *cursor = rec.frames_start_bit();
        parser.raise_latch();
        if !*clean_pad {
            synth.reset();
        }
    }
    let mut reader = asm.reader_at(*cursor);
    let mut failed = false;
    for _ in 0..rec.header.frame_count {
        if failed {
            break;
        }
        match parser.parse_frame(&mut reader) {
            Ok(frame) => {
                for block in &frame.blocks {
                    for (ch, chan) in synth.block(block).into_iter().enumerate() {
                        if ch < out.len() {
                            out[ch].extend_from_slice(&chan);
                        }
                    }
                }
            }
            Err(_) => {
                // §1 keeps the timeline: silence for the remaining
                // declared frames.
                for ch in out.iter_mut() {
                    ch.extend(std::iter::repeat(0.0).take(frame_len));
                }
                synth.reset();
                failed = true;
            }
        }
    }
    *cursor = reader.position() as u64;
    *clean_pad = if last {
        false
    } else {
        let next = asm.packets()[k + 1];
        !failed && next.header.carry_bits == 0 && *cursor <= next.body_start_bit
    };
}

/// f64 PCM in the ±1.0 convention → i32 full scale.
fn f2i(v: f64) -> i32 {
    let s = v.clamp(-1.0, 1.0) * 2147483647.0;
    s as i32
}

// ---------------------------------------------------------------------------
// C API
// ---------------------------------------------------------------------------

/// 1 when `data` looks like an ASF container holding a WMA v1/v2 audio
/// stream.
#[no_mangle]
pub extern "C" fn wma_sniff(data: *const u8, size: usize) -> c_int {
    if data.is_null() || size < 64 {
        return 0;
    }
    let slice = unsafe { std::slice::from_raw_parts(data, size) };
    match parse_asf_header(slice) {
        Some(a) if a.codec_tag == 0x0160 || a.codec_tag == 0x0161 => 1,
        _ => 0,
    }
}

/// Borrows `data` until `wma_close` (same contract as `ape_open_file`).
#[no_mangle]
pub extern "C" fn wma_open(data: *const u8, size: usize) -> *mut c_void {
    if data.is_null() || size < 64 {
        return std::ptr::null_mut();
    }
    let slice = unsafe { std::slice::from_raw_parts(data, size) };
    match open_internal(slice) {
        Ok(h) => Box::into_raw(Box::new(h)) as *mut c_void,
        Err(_) => std::ptr::null_mut(),
    }
}

/// 1 on success.
#[no_mangle]
pub extern "C" fn wma_info(handle: *const c_void, out: *mut WmaInfoFfi) -> c_int {
    if handle.is_null() || out.is_null() {
        return 0;
    }
    let h = unsafe { &*(handle as *const WmaHandle) };
    let info = WmaInfoFfi {
        sample_rate: h.sample_rate,
        channels: h.channels as u32,
        version: h.version,
        // Unknown until decode; the C side only needs it for a duration
        // hint. Decoding up front is expensive, so report a bound from
        // the packet count.
        total_samples: (h.packets.len() as u64).saturating_mul(u64::from(h.cfg.frame_length)),
    };
    unsafe { *out = info };
    1
}

/// Read up to `max_frames` interleaved-stereo frames into `out`
/// (`2 * max_frames` i32 values). Returns the frames written.
#[no_mangle]
pub extern "C" fn wma_read(handle: *mut c_void, out: *mut i32, max_frames: i64) -> i64 {
    if handle.is_null() || out.is_null() || max_frames <= 0 {
        return 0;
    }
    let h = unsafe { &mut *(handle as *mut WmaHandle) };
    if h.pcm.is_empty() {
        h.decode_all();
    }
    let total_frames = h.pcm.len() / 2;
    let avail = total_frames.saturating_sub(h.read_pos);
    let n = avail.min(max_frames as usize);
    if n == 0 {
        return 0;
    }
    let dst = unsafe { std::slice::from_raw_parts_mut(out, n * 2) };
    let src = &h.pcm[h.read_pos * 2..h.read_pos * 2 + n * 2];
    dst.copy_from_slice(src);
    h.read_pos += n;
    n as i64
}

/// Seek to interleaved frame `sample` (must be within range). 1 on
/// success, 0 on failure (matches `dts_seek`).
#[no_mangle]
pub extern "C" fn wma_seek(handle: *mut c_void, sample: u64) -> c_int {
    if handle.is_null() {
        return 0;
    }
    let h = unsafe { &mut *(handle as *mut WmaHandle) };
    if h.pcm.is_empty() {
        h.decode_all();
    }
    let total_frames = h.pcm.len() / 2;
    if sample as usize > total_frames {
        return 0;
    }
    h.read_pos = sample as usize;
    1
}

#[no_mangle]
pub extern "C" fn wma_close(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(handle as *mut WmaHandle));
    }
}
