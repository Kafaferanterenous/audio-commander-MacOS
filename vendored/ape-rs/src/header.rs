use std::io::{self, Read, Seek, SeekFrom};

use crate::error::ApeError;

/// APE magic bytes: "MAC " (0x4D 0x41 0x43 0x20)
const APE_MAGIC: [u8; 4] = [0x4D, 0x41, 0x43, 0x20];

/// Minimum supported format version (v3.99).
const MIN_VERSION: u16 = 3990;

/// APE descriptor — first structure in the file (52 bytes for v3.99+).
#[derive(Debug, Clone)]
pub struct ApeDescriptor {
    pub version: u16,
    pub descriptor_bytes: u32,
    pub header_bytes: u32,
    pub seek_table_bytes: u32,
    pub header_data_bytes: u32,
    pub ape_frame_data_bytes: u32,
    pub ape_frame_data_bytes_high: u32,
    pub terminating_data_bytes: u32,
    pub file_md5: [u8; 16],
}

/// APE header — follows the descriptor (24 bytes).
#[derive(Debug, Clone)]
pub struct ApeHeader {
    pub compression_level: u16,
    pub format_flags: u16,
    pub blocks_per_frame: u32,
    pub final_frame_blocks: u32,
    pub total_frames: u32,
    pub bits_per_sample: u16,
    pub channels: u16,
    pub sample_rate: u32,
}

/// Complete parsed file header: descriptor + header + seek table.
#[derive(Debug, Clone)]
pub struct ApeFileHeader {
    pub descriptor: ApeDescriptor,
    pub header: ApeHeader,
    /// Byte offsets to the start of each compressed frame.
    pub seek_table: Vec<u32>,
    /// Byte offset where compressed frame data begins.
    pub data_offset: u64,
}

impl ApeFileHeader {
    /// Total number of audio samples (blocks × channels).
    pub fn total_samples(&self) -> u64 {
        self.total_blocks() * self.header.channels as u64
    }

    /// Total number of audio blocks (one block = one sample per channel).
    pub fn total_blocks(&self) -> u64 {
        if self.header.total_frames == 0 {
            return 0;
        }
        let full_frames = (self.header.total_frames - 1) as u64;
        full_frames * self.header.blocks_per_frame as u64
            + self.header.final_frame_blocks as u64
    }
}

/// Parse an APE file header from a reader.
///
/// After this returns, the reader is positioned at the start of compressed
/// frame data.
pub fn parse_header<R: Read + Seek>(reader: &mut R) -> Result<ApeFileHeader, ApeError> {
    // Scan for "MAC " magic — there may be leading junk (ID3v2 tag, etc.)
    let desc_start = find_magic(reader)?;

    // Read descriptor (magic already consumed, reads remaining fields)
    let descriptor = read_descriptor(reader)?;

    // Seek to header start using descriptor_bytes (robust to future extensions)
    reader.seek(SeekFrom::Start(desc_start + descriptor.descriptor_bytes as u64))?;
    let header = read_header(reader)?;

    // Seek to seek table start
    let seek_table_start = desc_start
        + descriptor.descriptor_bytes as u64
        + descriptor.header_bytes as u64;
    reader.seek(SeekFrom::Start(seek_table_start))?;
    let seek_table = read_seek_table(reader, &descriptor)?;

    // Data offset: after descriptor + header + seek table + header data
    let data_offset = seek_table_start
        + descriptor.seek_table_bytes as u64
        + descriptor.header_data_bytes as u64;

    Ok(ApeFileHeader {
        descriptor,
        header,
        seek_table,
        data_offset,
    })
}

/// Scan forward to find the "MAC " magic bytes, returning the byte offset.
fn find_magic<R: Read + Seek>(reader: &mut R) -> Result<u64, ApeError> {
    let mut buf = [0u8; 4];
    reader.read_exact(&mut buf)?;

    if buf == APE_MAGIC {
        return Ok(0);
    }

    // Check for ID3v2 tag: starts with "ID3"
    if &buf[..3] == b"ID3" {
        // Read the rest of the ID3v2 header to get its size
        let mut id3_header = [0u8; 6]; // 6 more bytes after "ID3" + version byte we already read
        reader.read_exact(&mut id3_header)?;
        // ID3v2 size is a 28-bit syncsafe integer at bytes 6-9 of the header
        let size = ((id3_header[2] as u32) << 21)
            | ((id3_header[3] as u32) << 14)
            | ((id3_header[4] as u32) << 7)
            | (id3_header[5] as u32);
        let offset = 10 + size as u64; // 10-byte header + body
        reader.seek(SeekFrom::Start(offset))?;
        reader.read_exact(&mut buf)?;
        if buf == APE_MAGIC {
            return Ok(offset);
        }
    }

    Err(ApeError::InvalidMagic)
}

/// Read the APE descriptor (everything after the 4 magic bytes).
fn read_descriptor<R: Read>(reader: &mut R) -> Result<ApeDescriptor, ApeError> {
    let version = read_u16_le(reader)?;
    if version < MIN_VERSION {
        return Err(ApeError::UnsupportedVersion(version));
    }

    // 2 reserved/padding bytes after version
    let mut _padding = [0u8; 2];
    reader.read_exact(&mut _padding)?;

    let descriptor_bytes = read_u32_le(reader)?;
    let header_bytes = read_u32_le(reader)?;
    let seek_table_bytes = read_u32_le(reader)?;
    let header_data_bytes = read_u32_le(reader)?;
    let ape_frame_data_bytes = read_u32_le(reader)?;
    let ape_frame_data_bytes_high = read_u32_le(reader)?;
    let terminating_data_bytes = read_u32_le(reader)?;

    let mut file_md5 = [0u8; 16];
    reader.read_exact(&mut file_md5)?;

    Ok(ApeDescriptor {
        version,
        descriptor_bytes,
        header_bytes,
        seek_table_bytes,
        header_data_bytes,
        ape_frame_data_bytes,
        ape_frame_data_bytes_high,
        terminating_data_bytes,
        file_md5,
    })
}

/// Read the APE header (24 bytes).
fn read_header<R: Read>(reader: &mut R) -> Result<ApeHeader, ApeError> {
    let compression_level = read_u16_le(reader)?;
    let format_flags = read_u16_le(reader)?;
    let blocks_per_frame = read_u32_le(reader)?;
    let final_frame_blocks = read_u32_le(reader)?;
    let total_frames = read_u32_le(reader)?;
    let bits_per_sample = read_u16_le(reader)?;
    let channels = read_u16_le(reader)?;
    let sample_rate = read_u32_le(reader)?;

    // Validate
    if channels == 0 || channels > 2 {
        return Err(ApeError::InvalidHeader(format!(
            "unsupported channel count: {channels}"
        )));
    }
    if bits_per_sample != 8 && bits_per_sample != 16 && bits_per_sample != 24 {
        return Err(ApeError::InvalidHeader(format!(
            "unsupported bits per sample: {bits_per_sample}"
        )));
    }
    match compression_level {
        1000 | 2000 | 3000 | 4000 | 5000 => {}
        _ => return Err(ApeError::UnsupportedCompressionLevel(compression_level)),
    }

    Ok(ApeHeader {
        compression_level,
        format_flags,
        blocks_per_frame,
        final_frame_blocks,
        total_frames,
        bits_per_sample,
        channels,
        sample_rate,
    })
}

/// Read the seek table — array of u32 offsets, one per frame.
fn read_seek_table<R: Read>(
    reader: &mut R,
    descriptor: &ApeDescriptor,
) -> Result<Vec<u32>, ApeError> {
    let n_entries = descriptor.seek_table_bytes / 4;
    let mut table = Vec::with_capacity(n_entries as usize);
    for _ in 0..n_entries {
        table.push(read_u32_le(reader)?);
    }
    Ok(table)
}

// ── Little-endian helpers ────────────────────────────────────────────

fn read_u16_le<R: Read>(r: &mut R) -> Result<u16, io::Error> {
    let mut buf = [0u8; 2];
    r.read_exact(&mut buf)?;
    Ok(u16::from_le_bytes(buf))
}

fn read_u32_le<R: Read>(r: &mut R) -> Result<u32, io::Error> {
    let mut buf = [0u8; 4];
    r.read_exact(&mut buf)?;
    Ok(u32::from_le_bytes(buf))
}
