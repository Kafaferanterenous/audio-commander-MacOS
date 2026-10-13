use std::fmt;
use std::io;

/// Errors that can occur while decoding a Monkey's Audio (APE) file.
#[derive(Debug)]
pub enum ApeError {
    /// The file does not start with the APE magic bytes `MAC `.
    InvalidMagic,
    /// The format version is not supported (only v3.99+ / 3990+ supported).
    UnsupportedVersion(u16),
    /// The compression level is not recognized (expected 1000-5000).
    UnsupportedCompressionLevel(u16),
    /// A header field contains an invalid value.
    InvalidHeader(String),
    /// The seek table is missing or corrupt.
    InvalidSeekTable,
    /// A frame's CRC check failed.
    CrcMismatch { frame: u32, expected: u32, actual: u32 },
    /// The range coder encountered an invalid state.
    RangeCoderError(String),
    /// Unexpected end of data in a compressed frame.
    UnexpectedEof,
    /// A wrapped I/O error.
    Io(io::Error),
}

impl fmt::Display for ApeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ApeError::InvalidMagic => write!(f, "not a Monkey's Audio file (invalid magic)"),
            ApeError::UnsupportedVersion(v) => {
                write!(f, "unsupported APE format version: {v}")
            }
            ApeError::UnsupportedCompressionLevel(l) => {
                write!(f, "unsupported compression level: {l}")
            }
            ApeError::InvalidHeader(msg) => write!(f, "invalid APE header: {msg}"),
            ApeError::InvalidSeekTable => write!(f, "invalid or missing seek table"),
            ApeError::CrcMismatch {
                frame,
                expected,
                actual,
            } => {
                write!(
                    f,
                    "CRC mismatch in frame {frame}: expected {expected:#010x}, got {actual:#010x}"
                )
            }
            ApeError::RangeCoderError(msg) => write!(f, "range coder error: {msg}"),
            ApeError::UnexpectedEof => write!(f, "unexpected end of compressed data"),
            ApeError::Io(e) => write!(f, "I/O error: {e}"),
        }
    }
}

impl std::error::Error for ApeError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            ApeError::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<io::Error> for ApeError {
    fn from(e: io::Error) -> Self {
        ApeError::Io(e)
    }
}
