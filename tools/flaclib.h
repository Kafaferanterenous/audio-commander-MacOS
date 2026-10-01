/* Shared reference-signal generator + Ogg FLAC writer used by tools/flacgen.c
 * (fixture generation) and tools/test_oggflac.c (verification), so the writer
 * and the checker can never drift apart on the exact sample values.
 *
 * Sample values are produced right-justified to `bps`, which is what libFLAC's
 * encoder expects (stream_encoder.h: "each sample in the buffers should be a
 * signed integer, right-justified to the resolution set by
 * FLAC__stream_encoder_set_bits_per_sample()").
 */
#ifndef TOOLS_FLACLIB_H
#define TOOLS_FLACLIB_H

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "FLAC/stream_encoder.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define FLAC_BLOCK 4096

/* Deterministic multi-tone complex with a per-channel offset and an envelope
 * built from incommensurate low frequencies, so no two samples of a 1-2 s
 * window ever repeat: a decoder that renders the right audio at the WRONG
 * offset is then impossible to miss in a comparison. Peak stays around 0.85 of
 * full scale so nothing clips at any bit depth. */
static FLAC__int32 test_signal(long i, int ch, unsigned rate, unsigned bps) {
    double t = (double)i / (double)rate;
    double f = 110.0 + 37.0 * (double)ch;
    double v = 0.50 * sin(2.0 * M_PI * f * t + 0.3 * (double)ch)
             + 0.22 * sin(2.0 * M_PI * (f * 2.47) * t)
             + 0.13 * sin(2.0 * M_PI * ((double)rate / 8.0) * t)
                      * sin(2.0 * M_PI * 0.37 * t)
             + 0.09 * sin(2.0 * M_PI * 3.7 * t + 0.8 * (double)ch);
    double max = (double)(1u << (bps - 1)) - 1.0;
    long v32 = lround(v * max);
    if (v32 > (long)max) v32 = (long)max;
    if (v32 < -(long)max) v32 = -(long)max;
    return (FLAC__int32)v32;
}

static long test_frames(unsigned rate, double seconds) {
    return (long)((double)rate * seconds + 0.5);
}

/* Writes `frames` frames of test_signal() to `path`. Ogg FLAC unless the name
 * ends in .flac. Returns 1 on success; `verify` runs the decoder alongside the
 * encoder so a misconfigured stream fails here instead of in a fixture. */
static int flac_write(const char *path, unsigned rate, int ch, unsigned bps,
                      long frames, int level, int verify) {
    FLAC__StreamEncoder *enc = FLAC__stream_encoder_new();
    int ogg = strstr(path, ".flac") == NULL;
    FLAC__int32 *buf;
    FLAC__StreamEncoderInitStatus st;
    long done = 0;
    int ok = 1;

    if (!enc) return 0;
    if (FLAC__stream_encoder_set_verify(enc, verify ? true : false) != true
        || FLAC__stream_encoder_set_channels(enc, (unsigned)ch) != true
        || FLAC__stream_encoder_set_bits_per_sample(enc, bps) != true
        || FLAC__stream_encoder_set_sample_rate(enc, rate) != true
        || FLAC__stream_encoder_set_total_samples_estimate(enc,
                                                          (FLAC__uint64)frames) != true
        || FLAC__stream_encoder_set_compression_level(enc, level) != true) {
        FLAC__stream_encoder_delete(enc);
        return 0;
    }

    if (ogg)
        st = FLAC__stream_encoder_init_ogg_file(enc, path, NULL, NULL);
    else
        st = FLAC__stream_encoder_init_file(enc, path, NULL, NULL);
    if (st != FLAC__STREAM_ENCODER_INIT_STATUS_OK) {
        fprintf(stderr, "flac_write: init failed (%d) for %s\n", (int)st, path);
        FLAC__stream_encoder_delete(enc);
        return 0;
    }

    buf = (FLAC__int32 *)malloc((size_t)FLAC_BLOCK * (size_t)ch * sizeof(FLAC__int32));
    if (!buf) {
        FLAC__stream_encoder_finish(enc);
        FLAC__stream_encoder_delete(enc);
        return 0;
    }

    while (done < frames) {
        long n = frames - done;
        long i;
        int c;
        if (n > FLAC_BLOCK) n = FLAC_BLOCK;
        for (i = 0; i < n; i++) {
            for (c = 0; c < ch; c++)
                buf[i * ch + c] = test_signal(done + i, c, rate, bps);
        }
        if (!FLAC__stream_encoder_process_interleaved(enc, buf, (unsigned)n)) {
            ok = 0;
            break;
        }
        done += n;
    }

    /* finish() tears the encoder down (state becomes UNINITIALIZED), so its
     * return value - not get_state() afterwards - is what reports success. */
    if (ok && !FLAC__stream_encoder_finish(enc)) {
        fprintf(stderr, "flac_write: finish failed for %s (encoder state %d)\n",
                path, (int)FLAC__stream_encoder_get_state(enc));
        ok = 0;
    } else if (!ok) {
        fprintf(stderr, "flac_write: process failed for %s\n", path);
        (void)FLAC__stream_encoder_finish(enc);
    }

    free(buf);
    FLAC__stream_encoder_delete(enc);
    return ok;
}

/* One sample in the byte order/depth a WAV or raw PCM file expects. The signal
 * is right-justified in the int32 (that is how libFLAC reads it for bps < 32),
 * so the significant bytes are the low ones; 8-bit WAV is offset-binary. */
static inline int pcm_bytes(int32_t v, unsigned bps, int as_wav, unsigned char *out) {
    if (bps == 8) {
        out[0] = as_wav ? (unsigned char)((int8_t)v + 128) : (unsigned char)v;
        return 1;
    }
    out[0] = (unsigned char)v;
    out[1] = (unsigned char)((unsigned)v >> 8);
    if (bps == 24) {
        out[2] = (unsigned char)((unsigned)v >> 16);
        return 3;
    }
    if (bps == 16) return 2;
    out[2] = (unsigned char)((unsigned)v >> 16);
    out[3] = (unsigned char)((unsigned)v >> 24);
    return 4;
}

static inline int write_pcm(FILE *f, const char *path, unsigned rate, int ch,
                            unsigned bps, long frames, int as_wav) {
    int bytes = (int)((bps + 7) / 8);
    long i;
    for (i = 0; i < frames; i++) {
        int c;
        for (c = 0; c < ch; c++) {
            unsigned char sample[4];
            int n = pcm_bytes(test_signal(i, c, rate, bps), bps, as_wav, sample);
            if (fwrite(sample, 1, (size_t)n, f) != (size_t)n) {
                fprintf(stderr, "write_pcm: short write to %s\n", path);
                return 0;
            }
        }
    }
    return 1;
}

/* Headerless interleaved PCM, for piping into another encoder over stdin. */
static inline int raw_write(const char *path, unsigned rate, int ch, unsigned bps,
                            long frames) {
    FILE *f = fopen(path, "wb");
    int ok;
    if (!f) {
        fprintf(stderr, "raw_write: cannot create %s\n", path);
        return 0;
    }
    ok = write_pcm(f, path, rate, ch, bps, frames, 0);
    fclose(f);
    return ok;
}

/* Writes the same reference signal as a canonical RIFF/WAVE file so a
 * third-party encoder (the reference flac CLI) can be pointed at it and its
 * output compared against ours. */
static inline int wav_write(const char *path, unsigned rate, int ch, unsigned bps,
                            long frames) {
    FILE *f = fopen(path, "wb");
    unsigned bits = bps;
    int bytes = (int)((bps + 7) / 8);
    unsigned block_align = (unsigned)(ch * bytes);
    unsigned byte_rate = rate * block_align;
    unsigned data_bytes;
    unsigned char hdr[44];

    if (!f) {
        fprintf(stderr, "wav_write: cannot create %s\n", path);
        return 0;
    }
    data_bytes = (unsigned)(frames * (long)block_align);
    if (data_bytes > 0xFFFFFFF0u) {
        fprintf(stderr, "wav_write: %s is too long for RIFF\n", path);
        fclose(f);
        return 0;
    }
    memcpy(hdr + 0, "RIFF", 4);
    hdr[4] = (unsigned char)(36 + data_bytes); hdr[5] = (unsigned char)((36 + data_bytes) >> 8);
    hdr[6] = (unsigned char)((36 + data_bytes) >> 16); hdr[7] = (unsigned char)((36 + data_bytes) >> 24);
    memcpy(hdr + 8, "WAVE", 4);
    hdr[16] = 16; hdr[17] = 0; hdr[18] = 0; hdr[19] = 0;   /* fmt chunk size */
    hdr[12] = 'f'; hdr[13] = 'm'; hdr[14] = 't'; hdr[15] = ' ';
    hdr[20] = 1; hdr[21] = 0;                             /* PCM */
    hdr[22] = (unsigned char)ch; hdr[23] = 0;
    hdr[24] = (unsigned char)rate; hdr[25] = (unsigned char)(rate >> 8);
    hdr[26] = (unsigned char)(rate >> 16); hdr[27] = (unsigned char)(rate >> 24);
    hdr[28] = (unsigned char)byte_rate; hdr[29] = (unsigned char)(byte_rate >> 8);
    hdr[30] = (unsigned char)(byte_rate >> 16); hdr[31] = (unsigned char)(byte_rate >> 24);
    hdr[32] = (unsigned char)block_align; hdr[33] = (unsigned char)(block_align >> 8);
    hdr[34] = (unsigned char)bits; hdr[35] = (unsigned char)(bits >> 8);
    memcpy(hdr + 36, "data", 4);
    hdr[40] = (unsigned char)data_bytes; hdr[41] = (unsigned char)(data_bytes >> 8);
    hdr[42] = (unsigned char)(data_bytes >> 16); hdr[43] = (unsigned char)(data_bytes >> 24);
    if (fwrite(hdr, 1, 44, f) != 44) { fclose(f); return 0; }

    if (!write_pcm(f, path, rate, ch, bps, frames, 1)) {
        fclose(f);
        return 0;
    }
    fclose(f);
    return 1;
}

#endif /* TOOLS_FLACLIB_H */
