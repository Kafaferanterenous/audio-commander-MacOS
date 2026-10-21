/* WMA v1/v2 integration harness (#24).
 *
 * Drives the shipping dec_* API over the real ASF/WMA fixtures (three stereo
 * and three mono) and checks the decoded PCM for plausibility: stream open,
 * stereo 44100 output, a duration that matches the expected frame count,
 * non-silent content, working seek and (for the mono sources) that the two
 * output channels are identical. Unlike test_dts.c there is no ffmpeg-derived
 * reference PCM available on this host, so this verifies the C glue + ASF
 * reader + codec end to end rather than bit-exactness.
 *
 *   build/tools/test_wma [fixture-dir]     (default: tools/fixtures/wma)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "decoders.h"
#include "wma_ffi.h"

static int checks = 0, fails = 0;
static void check(int cond, const char *msg) {
    checks++;
    if (!cond) { fails++; printf("  FAIL %s\n", msg); }
}

static unsigned char *slurp(const char *path, long *size) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    *size = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *buf = malloc(*size ? *size : 1);
    if (fread(buf, 1, *size, f) != (size_t)*size) { fclose(f); free(buf); return NULL; }
    fclose(f);
    return buf;
}

/* Decode `name` fully. `expect_dur` is the expected File-Properties play
 * duration (< 0 to skip, e.g. a truncated excerpt with a stale header);
 * `expect_len` is the expected decoded length in seconds; `mono` marks a
 * mono source whose two output channels must be identical (the shim
 * duplicates mono to stereo before the shared converter). */
static void run_case(const char *dir, const char *name,
                     double expect_dur, double expect_len, int mono) {
    char path[1024];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    printf("== %s\n", name);

    long size = 0;
    unsigned char *data = slurp(path, &size);
    check(data != NULL, "fixture present");
    if (!data) return;

    check(wma_sniff(data, (size_t)size) == 1, "wma_sniff accepts ASF/WMA");

    void *dec = dec_open(data, (size_t)size);
    check(dec != NULL, "dec_open accepts WMA");
    if (!dec) { free(data); return; }

    check(dec_channels(dec) == 2, "output channels == 2");
    check(dec_sample_rate(dec) == 44100, "output rate == 44100");

    double dur = dec_duration(dec);
    check(dur > 0.0, "duration probe > 0");
    if (expect_dur > 0.0)
        check(fabs(dur - expect_dur) < 0.1, "duration within 0.1s of expected");

    enum { FR = 4096 };
    float buf[FR * 2];
    long long total = 0, nonzero = 0;
    double peak = 0.0, sumsq = 0.0;
    long long lr_mismatch = 0;
    for (;;) {
        int got = dec_render(dec, buf, FR);
        if (got <= 0) break;
        for (int f = 0; f < got; f++) {
            double l = buf[f * 2], r = buf[f * 2 + 1];
            if (mono && l != r) lr_mismatch++;
        }
        for (int i = 0; i < got * 2; i++) {
            double v = buf[i];
            if (v != 0.0f) nonzero++;
            if (fabs(v) > peak) peak = fabs(v);
            sumsq += v * v;
            total++;
        }
    }
    check(total > 0, "render produced samples");
    check(nonzero > total / 100, "content is not near-silent");
    check(peak > 0.001 && peak <= 1.0001, "peak in (0,1] (float scale)");
    double rms = sqrt(sumsq / (double)(total ? total : 1));
    check(rms < 0.9, "rms not implausibly hot");
    if (mono)
        check(lr_mismatch == 0, "mono source: L == R on every frame");

    double got_secs = (double)total / 2.0 / 44100.0;
    printf("   frames=%lld/2  %.3fs  dur=%.3fs  peak=%.4f  rms=%.4f  nonzero=%lld%s\n",
           total, got_secs, dur, peak, rms, nonzero,
           mono ? "  (mono)" : "");
    if (expect_len > 0.0)
        check(fabs(got_secs - expect_len) < 0.15, "decoded length within 0.15s");

    /* Seek to 0.5s and confirm playback resumes with content. */
    if (got_secs > 1.0) {
        check(dec_seek(dec, 0.5) == 1, "dec_seek(0.5) succeeds");
        int got = dec_render(dec, buf, 1024);
        check(got > 0, "render after seek produces samples");
        int nz = 0;
        for (int i = 0; i < got * 2; i++) if (buf[i] != 0.0f) nz++;
        printf("   post-seek(0.5) window: %d frames, nonzero=%d\n", got, nz);
    }

    dec_close(dec);
    free(data);
}

int main(int argc, char **argv) {
    const char *dir = argc > 1 ? argv[1] : "tools/fixtures/wma";
    /* Stereo fixtures. */
    run_case(dir, "twins.wma",    -1.0, 1.370, 0);   /* truncated excerpt: header duration is stale, decoded length still checked */
    run_case(dir, "sample15.wma", 15.000, 15.023, 0);
    run_case(dir, "example.wma",  36.130, 36.153, 0);
    /* Mono fixtures: also verify mono->stereo duplication (L == R). */
    run_case(dir, "wma_5s_sample_file_85KB.wma",    5.000, 5.039, 1);
    run_case(dir, "wma_15s_sample_file_254KB.wma", 15.000, 15.023, 1);
    run_case(dir, "wma_30s_sample_file_507KB.wma", 30.000, 30.023, 1);

    printf("\n%s: %d checks, %d failed\n", fails ? "FAIL" : "PASS", checks, fails);
    return fails ? 1 : 0;
}
