# ape-rs

Pure Rust decoder for [Monkey's Audio](https://www.monkeysaudio.com/) (APE) lossless audio files. Zero dependencies.

## Features

- Decodes APE v3.99+ (format version 3990) files to PCM samples
- All compression levels: Fast (1000), Normal (2000), High (3000), Extra High (4000), Insane (5000)
- Mono and stereo
- 8-bit, 16-bit, and 24-bit sample depths
- Bit-exact output (verified against FFmpeg across millions of samples)
- No unsafe code
- No dependencies beyond `std`

## Usage

Add to your `Cargo.toml`:

```toml
[dependencies]
ape-rs = { git = "https://github.com/lexicone42/ape-rs" }
```

Decode an APE file:

```rust
use ape_rs::ApeReader;

let mut reader = ApeReader::open("track.ape").unwrap();
let info = reader.info();
println!("{}ch, {}Hz, {}bit", info.channels, info.sample_rate, info.bits_per_sample);

// Iterate over interleaved i32 PCM samples
for sample in reader.samples() {
    let sample: i32 = sample.unwrap();
    // For stereo files, samples alternate: [L0, R0, L1, R1, ...]
    // Normalize to f32 with: sample as f32 / 2^(bits_per_sample - 1)
}
```

Or collect all samples at once:

```rust
use ape_rs::ApeReader;

let mut reader = ApeReader::open("track.ape").unwrap();
let samples: Vec<i32> = reader.samples().collect::<Result<_, _>>().unwrap();
```

## API

### `ApeReader`

| Method | Description |
|--------|-------------|
| `ApeReader::open(path)` | Open an APE file by path |
| `ApeReader::new(reader)` | Create from any `Read + Seek` source |
| `.info()` | Returns `&ApeInfo` with metadata |
| `.samples()` | Returns an iterator over `Result<i32, ApeError>` |

### `ApeInfo`

| Field | Type | Description |
|-------|------|-------------|
| `sample_rate` | `u32` | Sample rate in Hz (e.g. 44100) |
| `channels` | `u16` | 1 (mono) or 2 (stereo) |
| `bits_per_sample` | `u16` | 8, 16, or 24 |
| `total_samples` | `u64` | Total interleaved samples (blocks x channels) |
| `compression_level` | `u16` | 1000-5000 |
| `format_version` | `u16` | e.g. 3990 |

## Architecture

```
src/
  lib.rs          Public API (ApeReader, ApeInfo, ApeSamples iterator)
  header.rs       APE descriptor, header, and seek table parsing
  range_coder.rs  Arithmetic entropy decoder
  nnfilter.rs     Adaptive FIR filter (sign-LMS, 0-3 stages by level)
  predictor.rs    Linear predictor + stereo channel decorrelation
  decode.rs       Frame decoding pipeline
  buffer.rs       Sample buffering and interleaving
  error.rs        Error types
```

Per-frame decode pipeline:
1. Seek to frame offset, read and byte-swap compressed data
2. Skip frame header (alignment, CRC, optional flags)
3. Range-decode entropy-coded residuals
4. NNFilter inverse (adaptive FIR, restores short-term correlation)
5. Predictor inverse (linear prediction, restores long-term correlation)
6. Channel decorrelation inverse (mid/side to L/R for stereo)

## Testing

The test suite verifies bit-exact decoding across all 10 configurations (mono/stereo x 5 compression levels). To run tests, generate test data with the [MAC encoder](https://github.com/fernandotcl/monkeys-audio) and place files in `tests/data/`:

```bash
# Create test WAV files, then encode at each level:
mac input.wav tests/data/test_mono_c2000.ape -c2000

# Run tests
cargo test --release
```

## Limitations

- Only APE v3.99+ (format version >= 3990). Older versions (v3.93-v3.97) use a different header layout.
- No APEv2 tag parsing (metadata tags at EOF are ignored).
- No encoding, decode only.

## Implementation notes

This is an original Rust implementation. The Monkey's Audio format has limited public documentation; behavior was derived from the format header specification and empirical testing against FFmpeg's decoder output. Output is verified bit-exact against FFmpeg across millions of samples.

## License

MIT

## Acknowledgments

[Monkey's Audio](https://www.monkeysaudio.com/) is by Matthew T. Ashland. [FFmpeg](https://ffmpeg.org/) (LGPL) was used as a reference for verification.
