/* Verification harness for the Ogg FLAC decoder path (goal #15).
 *
 * Two kinds of input are checked with the same battery:
 *
 *  1. files written by the vendored libFLAC encoder (tools/flacgen.c) from the
 *     shared reference tone, and
 *  2. files written by the *reference* flac 1.5.0 CLI (tools/gen_flac_fixtures.sh
 *     stage 2), so the decoder is also proven against a third-party encoder
 *     with its own padding / Vorbis comment / seektable layout.
 *
 * Everything is decoded through the app's real decoders.c path (dec_open /
 * dec_render / dec_seek / dec_probe_duration) and compared against the
 * in-memory reference:
 *
 *   - exact sample equality at the native 44.1 kHz rate (FLAC is lossless and
 *     the app's 44.1 kHz path is a straight scale)
 *   - mono -> duplicated L/R, 5.1 -> first two channels
 *   - frame counts, duration and dec_probe_duration agreement
 *   - resampled rates (22.05/48/96 kHz): length, loudness, first-sample anchor
 *   - sample-accurate seeking (mid, back to 0, negative clamp, past the end)
 *   - truncated and corrupt streams fail or stop cleanly, garbage stays NULL
 *
 * Usage: test_oggflac [scratch_dir]
 */
#include "flaclib.h"
#include "decoders.h"

static int checks = 0;
static int failures = 0;
static const char *scratch = "build/tools/scratch";

static void check(int cond, const char *label) {
    checks++;
    if (cond) {
        printf("   ok   %s\n", label);
    } else {
        failures++;
        printf("   FAIL %s\n", label);
    }
}

static void checkf(int cond, const char *label, double got, double want, double tol) {
    char buf[256];
    snprintf(buf, sizeof buf, "%s (got %.9g, want %.9g, tol %.3g)", label, got, want, tol);
    check(cond, buf);
}

static char *slurp(const char *path, long *size) {
    FILE *f = fopen(path, "rb");
    unsigned char *buf;
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    *size = ftell(f);
    fseek(f, 0, SEEK_SET);
    buf = (unsigned char *)malloc((size_t)(*size ? *size : 1));
    if (fread(buf, 1, (size_t)*size, f) != (size_t)*size) {
        fclose(f);
        free(buf);
        return NULL;
    }
    fclose(f);
    return (char *)buf;
}

static double rms(const float *x, long n) {
    double s = 0.0;
    long i;
    for (i = 0; i < n; i++) s += (double)x[i] * (double)x[i];
    return sqrt(s / (double)(n ? n : 1));
}

/* normalized reference sample as the app's float path must produce it */
static double ref_norm(long i, int channel, unsigned rate, unsigned bps) {
    return (double)test_signal(i, channel, rate, bps) / (double)(1u << (bps - 1));
}

static double ref_rms(long frames, int ch, unsigned rate, unsigned bps) {
    double s = 0.0;
    long i;
    for (i = 0; i < frames; i++) {
        int c;
        for (c = 0; c < (ch >= 2 ? 2 : 1); c++) {
            double v = (double)test_signal(i, c, rate, bps) / (double)(1u << (bps - 1));
            s += v * v;
        }
    }
    return sqrt(s / (double)(frames * (ch >= 2 ? 2 : 1)));
}

/* Offset just past the first page that carries audio (granulepos > 0), or 0 if
 * there is none. Ogg only hands a page to the decoder once it is complete, so
 * this is what decides how much a truncated file can still decode. */
static long first_audio_page_end(const char *data, long size) {
    long off = 0;
    while (off + 27 <= size) {
        unsigned char nsegs;
        long body, end;
        unsigned long long gran;
        if (memcmp(data + off, "OggS", 4) != 0) return 0;
        gran = 0;
        {
            int i;
            for (i = 0; i < 8; i++) gran |= (unsigned long long)(unsigned char)data[off + 6 + i] << (8 * i);
        }
        nsegs = (unsigned char)data[off + 26];
        body = 0;
        {
            int i;
            for (i = 0; i < nsegs; i++) body += (unsigned char)data[off + 27 + i];
        }
        end = off + 27 + nsegs + body;
        if (end > size) return 0;          /* incomplete page: not usable */
        if (gran > 0) return end;
        off = end;
    }
    return 0;
}

/* Renders into the caller's buffer until EOF or `cap` frames. */
static long render_all(void *d, float *out, long cap) {
    long total = 0;
    while (total < cap) {
        long n = dec_render(d, out + total * 2, cap - total);
        if (n <= 0) break;
        total += n;
    }
    return total;
}

/* Renders (and discards) to count frames, so tests never overflow a buffer. */
static long render_count(void *d, long cap) {
    float scratch[4096];
    long total = 0;
    for (;;) {
        long n = dec_render(d, scratch, 2048);
        if (n <= 0) break;
        total += n;
        if (total >= cap) break;
    }
    return total;
}

/* Renders `count` frames and reports the largest deviation from the reference
 * starting at `from`. Returns -1 when the render is too short. */
static double max_dev(void *d, long from, long count, unsigned rate, int ch,
                      unsigned bps) {
    float *buf = (float *)malloc((size_t)count * 2 * sizeof(float));
    long i, n = dec_render(d, buf, count);
    double maxerr = 0.0;
    for (i = 0; i < n; i++) {
        double l = (double)test_signal(from + i, 0, rate, bps) / (double)(1u << (bps - 1));
        double r = (ch >= 2) ? (double)test_signal(from + i, 1, rate, bps) / (double)(1u << (bps - 1))
                             : l;
        double el = fabs((double)buf[i * 2] - l);
        double er = fabs((double)buf[i * 2 + 1] - r);
        if (el > maxerr) maxerr = el;
        if (er > maxerr) maxerr = er;
    }
    free(buf);
    return n == count ? maxerr : -1.0;
}

/* The sample index a seek to `seconds` must land on, mirroring dec_seek(): the
 * nearest source sample, computed the same way (so 0.25 s of a 22050 Hz file is
 * sample 5513, not the integer 5512). */
static long seek_index(double seconds, unsigned rate) {
    return (long)(unsigned long long)(seconds * (double)rate + 0.5);
}

/* First sample the decoder emits after a seek, so resampled files (where a run
 * of output samples cannot be bit-exact) can still be checked sample-accurately.
 * Returns -2.0 when nothing could be rendered. */
static double first_after_seek(void *d) {
    float buf[8];
    long n = dec_render(d, buf, 1);
    if (n != 1) return -2.0;
    return (double)buf[0];
}

static void check_seek(const char *label, const char *path, int ch, unsigned bps,
                       unsigned rate, long frames) {
    long size = 0;
    char *data = slurp(path, &size);
    void *d;
    /* Bit-exact runs only hold when the file already plays at the output rate;
     * otherwise every sample except a direct hit is interpolated. */
    int direct = (rate == 44100);
    double dur = (double)frames / (double)rate;
    long mid = seek_index(0.5 * dur, rate);
    long at = seek_index(0.5 * dur, rate);
    double want_mid = ref_norm(mid, 0, rate, bps);

    if (!data) {
        check(0, label);
        return;
    }
    d = dec_open(data, (size_t)size);
    if (!d) {
        check(0, label);
        free(data);
        return;
    }
    printf("== seek: %s\n", label);

    {
        int ok = dec_seek(d, 0.5 * dur);
        double got = ok ? (direct ? max_dev(d, mid, 1024, rate, ch, bps)
                                  : first_after_seek(d) - want_mid)
                        : 1.0;
        checkf(ok && got == 0.0, "seek to the middle is sample accurate",
               ok ? got : 1.0, 0.0, 0.0);
    }
    {
        int ok = dec_seek(d, 0.0);
        double got = ok ? (direct ? max_dev(d, 0, 1024, rate, ch, bps)
                                  : first_after_seek(d) - ref_norm(0, 0, rate, bps))
                        : 1.0;
        checkf(ok && got == 0.0, "seek back to zero replays from the start",
               ok ? got : 1.0, 0.0, 0.0);
    }
    {
        int ok = dec_seek(d, -3.0);
        double got = ok ? (direct ? max_dev(d, 0, 512, rate, ch, bps)
                                  : first_after_seek(d) - ref_norm(0, 0, rate, bps))
                        : 1.0;
        checkf(ok && got == 0.0, "negative seek clamps to the start", ok ? got : 1.0,
               0.0, 0.0);
    }
    {
        /* random-access chain: seeking backwards must work too. Targets are
         * fractions of the file's duration so they stay inside the stream. */
        int ok = dec_seek(d, 0.8 * dur) && dec_seek(d, 0.2 * dur) && dec_seek(d, 0.5 * dur);
        double got = ok ? (direct ? max_dev(d, at, 256, rate, ch, bps)
                                  : first_after_seek(d) - ref_norm(at, 0, rate, bps))
                        : 1.0;
        checkf(ok && got == 0.0, "seek chain 80% -> 20% -> 50%", ok ? got : 1.0, 0.0, 0.0);
    }
    {
        float buf[2048];
        int ok = dec_seek(d, (double)frames / (double)rate + 5.0);
        long n = dec_render(d, buf, 1024);
        check(!ok || n == 0, "seek past the end is refused or yields silence");
    }
    {
        /* Seek to 1000 source frames before the end: the tail must decode
         * exactly and stop there rather than running on or off the end. */
        long target = seek_index((double)(frames - 1000) / (double)rate, rate);
        long expect = direct ? (frames - target) : (frames - target) * 2;
        long total = 0;
        int match = 1;
        float buf[2048];
        if (dec_seek(d, (double)target / (double)rate)) {
            for (;;) {
                long n, k;
                n = dec_render(d, buf, 512);
                if (n <= 0) break;
                if (direct) {
                    for (k = 0; k < n; k++) {
                        if (buf[k * 2] != ref_norm(target + total + k, 0, rate, bps)) match = 0;
                    }
                } else if (total == 0) {
                    match = ((double)buf[0] == ref_norm(target, 0, rate, bps));
                }
                total += n;
                if (total > 4096) break;
            }
        }
        checkf(total == expect && match, "render after a near-end seek stops at the end",
               (double)total, (double)expect, 0);
    }
    dec_close(d);
    free(data);
}

/* Full battery for one Ogg FLAC file known to hold the reference tone. */
static void check_stream(const char *label, const char *path, unsigned rate, int ch,
                         unsigned bps, long frames) {
    long size = 0;
    char *data = slurp(path, &size);
    void *d;
    double dur, expect_dur;
    long cap, got;
    float *out;
    char buf[256];

    printf("== %s\n", label);
    if (!data || size <= 0) {
        check(0, "file is readable");
        free(data);
        return;
    }
    check(memcmp(data, "OggS", 4) == 0, "file is an Ogg stream");
    d = dec_open(data, (size_t)size);
    check(d != NULL, "dec_open accepts Ogg FLAC");
    if (!d) {
        free(data);
        return;
    }

    dur = dec_duration(d);
    expect_dur = (double)frames / (double)rate;
    checkf(dur > 0 && fabs(dur - expect_dur) < 1e-6, "duration", dur, expect_dur, 1e-6);
    checkf(fabs(dec_probe_duration(data, (size_t)size) - dur) < 1e-9,
           "dec_probe_duration matches dec_duration", dur, dur, 1e-9);
    check(dec_channels(d) == 2, "output is stereo");
    check(dec_sample_rate(d) == 44100, "output is 44.1 kHz");

    cap = (long)((double)frames * 44100.0 / (double)rate) + 8192;
    out = (float *)malloc((size_t)cap * 2 * sizeof(float));
    got = render_all(d, out, cap);
    check(got > 0, "render produced audio");
    if (got <= 0) {
        free(out);
        dec_close(d);
        free(data);
        return;
    }

    {
        double want = (rate == 44100) ? (double)frames
                                      : (double)frames * 44100.0 / (double)rate;
        checkf(fabs((double)got - want) <= 2.0, "rendered frame count", (double)got, want, 2.0);
    }

    if (rate == 44100) {
        /* Lossless + direct rate: every sample must match the reference. Up to
         * 24 bits per sample the quotient is exact in float32; at 32 bits it
         * needs more mantissa than float32 has, so allow one ULP there. */
        double tol = (bps > 24) ? 1.2e-7 : 0.0;
        double maxerr = 0.0;
        long i, n = got < frames ? got : frames;
        for (i = 0; i < n; i++) {
            double l = ref_norm(i, 0, rate, bps);
            double r = (ch >= 2) ? ref_norm(i, 1, rate, bps) : l;
            double el = fabs((double)out[i * 2] - l);
            double er = fabs((double)out[i * 2 + 1] - r);
            if (el > maxerr) maxerr = el;
            if (er > maxerr) maxerr = er;
        }
        checkf(maxerr <= tol, "every sample bit-exact vs reference", maxerr, 0.0, tol);
        checkf(got == frames, "rendered exactly every source frame", (double)got,
               (double)frames, 0.0);
        if (ch == 1) {
            int same = 1;
            long i;
            for (i = 0; i < got; i++)
                if (out[i * 2] != out[i * 2 + 1]) { same = 0; break; }
            check(same, "mono is duplicated into L and R");
        }
        if (ch > 2) {
            int first_two = 1;
            long i;
            for (i = 0; i < got; i++) {
                if (out[i * 2] != ref_norm(i, 0, rate, bps)
                    || out[i * 2 + 1] != ref_norm(i, 1, rate, bps)) {
                    first_two = 0;
                    break;
                }
            }
            check(first_two, "multichannel takes the first two channels");
        }
    } else {
        /* Resampled: length was checked above, so anchor the first sample and
         * verify the level survives interpolation. */
        double l0 = (double)test_signal(0, 0, rate, bps) / (double)(1u << (bps - 1));
        double want_rms = ref_rms(frames, ch, rate, bps);
        checkf(fabs((double)out[0] - l0) < 1e-6,
               "first output sample is the first input sample", (double)out[0], l0, 1e-6);
        checkf(fabs(rms(out, got * 2) - want_rms) <= 0.02 * want_rms + 1e-4,
               "resampled loudness preserved", rms(out, got * 2), want_rms,
               0.02 * want_rms + 1e-4);
    }
    free(out);

    snprintf(buf, sizeof buf, "dec_position %.4fs", dec_position(d));
    checkf(fabs(dec_position(d) - expect_dur) < 0.01, buf, dec_position(d), expect_dur, 0.01);

    /* stream integrity: truncated, bit-flipped and garbage inputs */
    {
        /* Truncate right after the first page that carries audio, and again a
         * few bytes into the next page. Ogg hands over only complete pages, so
         * the first cut must still decode that audio and never more than the
         * header promises; the ragged cut must not decode any less. */
        long cut = first_audio_page_end(data, size);
        long expect_out = (rate == 44100) ? frames
                                           : (long)((double)frames * 44100.0 / (double)rate) + 2;
        long whole = 0, ragged = 0;
        check(cut > 0 && cut <= size, "located the first audio page boundary");
        if (cut > 0) {
            void *t = dec_open(data, (size_t)cut);
            check(t != NULL, "stream cut at a page boundary still opens");
            if (t) {
                whole = render_count(t, 1000000);
                dec_close(t);
            }
            t = dec_open(data, (size_t)(cut + 20 < size ? cut + 20 : size));
            check(t != NULL, "stream cut mid-page still opens");
            if (t) {
                ragged = render_count(t, 1000000);
                dec_close(t);
            }
        }
        checkf(whole > 0, "truncated stream renders its surviving audio", (double)whole,
               1, 0);
        checkf(whole <= expect_out && ragged <= expect_out,
               "truncated stream never invents samples", (double)(whole > ragged ? whole : ragged),
               (double)expect_out, 0);
        checkf(ragged >= whole, "a ragged cut decodes at least as much as a clean one",
               (double)ragged, (double)whole, 0);
    }
    {
        unsigned char *copy = (unsigned char *)malloc((size_t)size);
        long i;
        void *t;
        memcpy(copy, data, (size_t)size);
        for (i = size / 2; i < size; i += 97) copy[i] ^= 0xFF;
        t = dec_open(copy, (size_t)size);
        check(t != NULL, "bit-flipped audio region still opens");
        if (t) {
            long total = render_count(t, 1000000);
            check(total >= 0 && total <= frames, "bit-flipped stream terminates cleanly");
            dec_close(t);
        }
        /* destroyed FLAC mapping magic -> not FLAC, not vorbis: refuse */
        for (i = 0; i + 4 < 64; i++) {
            if (memcmp(copy + i, "\x7f" "FLAC", 5) == 0) {
                memcpy(copy + i + 1, "XXXX", 4);
                break;
            }
        }
        t = dec_open(copy, (size_t)size);
        check(t == NULL, "non-FLAC Ogg payload is refused");
        if (t) dec_close(t);
        free(copy);
    }
    {
        void *t = dec_open(data, 4);
        check(t == NULL, "\"OggS\" alone is refused");
        if (t) dec_close(t);
    }
    {
        /* Damage the first-page payload magic that the pre-flight sniff keys on,
           leaving everything else intact, and confirm each variant is refused
           cleanly (never re-probed as a tracker module).
           packet start = 27 + segment count at offset 26. */
        unsigned char copy[1 << 20];
        void *t;
        if (size <= (long)sizeof copy && memcmp(data, "OggS", 4) == 0) {
            long pk = 27 + data[26];
            memcpy(copy, data, (size_t)size);
            memcpy(copy + pk + 1, "XXXX", 4);      /* keep the 0x7F/0x01 marker */
            t = dec_open(copy, (size_t)size);
            check(t == NULL, "Ogg FLAC with a destroyed payload magic is refused");
            if (t) dec_close(t);

            memcpy(copy, data, (size_t)size);
            copy[4] = 0x02;                        /* wrong Ogg page version */
            t = dec_open(copy, (size_t)size);
            check(t == NULL, "Ogg FLAC with a wrong page version is refused");
            if (t) dec_close(t);

            memcpy(copy, data, (size_t)size);
            copy[26] = 0x00;                       /* no segments => no packet */
            t = dec_open(copy, (size_t)size);
            check(t == NULL, "Ogg FLAC with an empty first-page segment table is refused");
            if (t) dec_close(t);
        }
    }
    {
        unsigned char junk[600];
        unsigned seed = 12345u;
        long i;
        void *t;
        for (i = 0; i < 600; i++) {
            seed = seed * 1103515245u + 12345u;
            junk[i] = (unsigned char)(seed >> 16);
        }
        junk[0] = 'O'; junk[1] = 'g'; junk[2] = 'g'; junk[3] = 'S';
        t = dec_open(junk, sizeof junk);
        check(t == NULL, "OggS + random bytes is refused");
        if (t) dec_close(t);
    }
    {
        void *t = dec_open(data, 0);
        check(t == NULL, "empty input is refused");
        if (t) dec_close(t);
    }
    {
        /* dec_open copies the file: scribbling over the caller's buffer after
         * opening must not disturb decoding that is already under way */
        void *h = dec_open(data, (size_t)size);
        check(h != NULL, "reopen for the aliasing check");
        if (h) {
            memset(data, 0xAA, 4096);
            if (rate == 44100) {
                double tol = (bps > 24) ? 1.2e-7 : 0.0;
                double dev = max_dev(h, 0, 256, rate, ch, bps);
                checkf(dev >= 0.0 && dev <= tol,
                       "decoding continues from dec_open's own copy of the data",
                       dev, 0.0, tol);
            } else {
                double l0 = (double)test_signal(0, 0, rate, bps) / (double)(1u << (bps - 1));
                float *b2 = (float *)malloc(512 * sizeof(float));
                long n = dec_render(h, b2, 1);
                checkf(n == 1 && fabs((double)b2[0] - l0) < 1e-6,
                       "decoding continues from dec_open's own copy of the data",
                       n == 1 ? (double)b2[0] : 0.0, l0, 1e-6);
                free(b2);
            }
            dec_close(h);
        }
    }

    dec_close(d);
    free(data);
}

/* The fixture matrix: every entry is generated by tools/gen_flac_fixtures.sh,
 * verified as a freshly written file and then again from what is committed. */
struct spec {
    const char *name;
    unsigned rate;
    int ch;
    unsigned bps;
    double secs;
};

static const struct spec specs[] = {
    { "s16_44100_stereo", 44100, 2, 16, 1.0 },
    { "s24_44100_stereo", 44100, 2, 24, 0.5 },
    { "s32_44100_stereo", 44100, 2, 32, 0.25 },
    { "s8_44100_stereo",  44100, 2, 8,  0.5 },
    { "s16_44100_mono",  44100, 1, 16, 0.5 },
    { "s16_44100_5ch",   44100, 5, 16, 0.5 },
    { "s16_22050_mono",  22050, 1, 16, 0.5 },
    { "s24_48000_stereo", 48000, 2, 24, 0.5 },
    { "s24_96000_stereo", 96000, 2, 24, 0.5 },
};

static void test_spec(const char *name, unsigned rate, int ch, unsigned bps,
                      double secs) {
    char path[512];
    long frames = test_frames(rate, secs);
    long size = 0;
    char *probe;

    snprintf(path, sizeof path, "%s/%s.oga", scratch, name);
    printf("== encode %s (%u Hz, %d ch, %u bps, %ld frames)\n", name, rate, ch, bps, frames);
    if (!flac_write(path, rate, ch, bps, frames, 5, 1)) {
        check(0, "vendored libFLAC Ogg encoder writes the reference");
        return;
    }
    check(1, "vendored libFLAC Ogg encoder writes the reference");
    probe = slurp(path, &size);
    if (probe) {
        /* 32-bit content is near-incompressible, so only demand real
         * compression for the narrower depths */
        check(bps == 32 || size < frames * (long)ch * (long)((bps + 7) / 8) / 2,
              "encoded file is smaller than the raw PCM (real compression)");
        free(probe);
    }
    check_stream(name, path, rate, ch, bps, frames);
}

/* Seek battery for one entry of the spec matrix, run against the committed file
 * so what is checked is exactly what ships. */
static void seek_spec(const char *name) {
    size_t i;
    char path[512];
    for (i = 0; i < sizeof specs / sizeof specs[0]; i++) {
        if (strcmp(specs[i].name, name) != 0) continue;
        snprintf(path, sizeof path, "tools/fixtures/%s.oga", name);
        check_seek(name, path, specs[i].ch, specs[i].bps, specs[i].rate,
                   test_frames(specs[i].rate, specs[i].secs));
        return;
    }
    fprintf(stderr, "seek_spec: no spec named %s\n", name);
}

struct ext {
    const char *path;
    const char *label;
    unsigned rate;
    int ch;
    unsigned bps;
    long frames;
};

int main(int argc, char **argv) {
    /* files written by the reference flac CLI, if tools/gen_flac_fixtures.sh
     * has produced them (build/tools/ref/) */
    static const struct ext external[] = {
        { "build/tools/ref/r16_44100_2.oga", "reference flac 1.5.0 CLI, s16 44.1k stereo",
          44100, 2, 16, 44100 },
        { "build/tools/ref/r24_48000_2.oga", "reference flac 1.5.0 CLI, s24 48k stereo",
          48000, 2, 24, 24000 },
        { "build/tools/ref/r16_22050_1.oga", "reference flac 1.5.0 CLI, s16 22.05k mono",
          22050, 1, 16, 22050 },
    };
    size_t i;

    if (argc > 1) scratch = argv[1];
    printf("Ogg FLAC decoder verification (scratch: %s)\n\n", scratch);

    for (i = 0; i < sizeof specs / sizeof specs[0]; i++)
        test_spec(specs[i].name, specs[i].rate, specs[i].ch, specs[i].bps, specs[i].secs);

    printf("\n");
    for (i = 0; i < sizeof specs / sizeof specs[0]; i++) {
        char path[512];
        long size = 0;
        char *probe;
        snprintf(path, sizeof path, "tools/fixtures/%s.oga", specs[i].name);
        probe = slurp(path, &size);
        if (!probe) {
            printf("== committed %s: missing, skipped\n", path);
            continue;
        }
        free(probe);
        check_stream(specs[i].name, path, specs[i].rate, specs[i].ch, specs[i].bps,
                     test_frames(specs[i].rate, specs[i].secs));
    }

    printf("\n");
    for (i = 0; i < sizeof external / sizeof external[0]; i++) {
        long size = 0;
        char *probe = slurp(external[i].path, &size);
        if (!probe) {
            printf("== %s: not built, skipped\n", external[i].label);
            continue;
        }
        free(probe);
        check_stream(external[i].label, external[i].path, external[i].rate,
                     external[i].ch, external[i].bps, external[i].frames);
    }

    seek_spec("s16_44100_stereo");
    seek_spec("s24_44100_stereo");
    seek_spec("s16_44100_mono");
    seek_spec("s16_44100_5ch");
    seek_spec("s16_22050_mono");
    check_seek("reference flac CLI s16 44.1k stereo", "build/tools/ref/r16_44100_2.oga",
               2, 16, 44100, 44100);
    check_seek("reference flac CLI s16 22.05k mono", "build/tools/ref/r16_22050_1.oga",
               1, 16, 22050, 22050);

    printf("\n%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
