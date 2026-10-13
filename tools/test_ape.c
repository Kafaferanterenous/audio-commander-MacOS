/* Monkey's Audio (APE) integration harness (#22).
 *
 * Drives the shipping dec_* API over a small, frame-aligned APE fixture and
 * checks the decoded PCM against the *independent* ffmpeg-derived reference
 * (tools/fixtures/ape/reference.s16le) that ships alongside it. It also
 * exercises seek + end-of-stream, so the C glue (mono->stereo, scale, frame
 * blocking) is verified end to end rather than only the Rust decoder.
 *
 *   build/tools/test_ape [fixture-dir]     (default: tools/fixtures/ape)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "decoders.h"

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

/* Left channel of the stereo render, back to the stored 16-bit scale. */
static long l16(const float *stereo, long i) {
    return lroundf(stereo[i * 2] * 32768.0f);
}

int main(int argc, char **argv) {
    const char *dir = argc > 1 ? argv[1] : "tools/fixtures/ape";
    char apath[1024], rpath[1024];
    snprintf(apath, sizeof apath, "%s/sample.ape", dir);
    snprintf(rpath, sizeof rpath, "%s/reference.s16le", dir);

    long asize = 0, rsize = 0;
    unsigned char *adata = slurp(apath, &asize);
    unsigned char *rdata = slurp(rpath, &rsize);
    printf("== APE integration ==\n");
    check(adata != NULL, "read sample.ape");
    check(rdata != NULL, "read reference.s16le");
    if (!adata || !rdata) { free(adata); free(rdata); printf("FAILURES\n"); return 1; }
    const long refN = rsize / 2;
    const short *ref = (const short *)rdata;

    /* Guard against a useless all-silent fixture: the source has a quiet
       lead-in, so require real signal somewhere. */
    int peak = 0;
    for (long i = 0; i < refN; i++) {
        int v = ref[i] < 0 ? -ref[i] : ref[i];
        if (v > peak) peak = v;
    }
    check(peak > 1000, "fixture carries real signal");

    void *d = dec_open(adata, asize);
    check(d != NULL, "dec_open");
    if (!d) { free(adata); free(rdata); printf("FAILURES\n"); return 1; }

    double dur = dec_duration(d);
    printf("   duration %.3fs rate %u ch %u\n", dur, dec_sample_rate(d), dec_channels(d));
    check(fabs(dur - 13.3747) < 0.01, "duration ~13.375s");
    check(dec_sample_rate(d) == 44100, "rate 44100");
    check(dec_channels(d) == 2, "stereo output");

    /* Full decode, comparing every sample to the reference. */
    float buf[2048];
    long idx = 0, total = 0, mism = 0;
    for (;;) {
        long n = dec_render(d, buf, 1024);
        if (n <= 0) break;
        for (long i = 0; i < n; i++) {
            if (idx < refN && l16(buf, i) != ref[idx]) mism++;
            idx++;
        }
        total += n;
    }
    printf("   rendered %ld frames (%.3fs), mismatches %ld\n",
           total, total / 44100.0, mism);
    check(total == refN, "rendered length == reference");
    check(mism == 0, "bit-exact vs ffmpeg reference");

    /* Sample-accurate seek: window after each seek must equal the reference.
       Positions land in the musical portion (the fixture leads in quietly). */
    const long positions[3] = { 400000, 500000, 580000 };
    for (int k = 0; k < 3; k++) {
        long p = positions[k];
        int ok = dec_seek(d, (double)p / 44100.0);
        check(ok, "dec_seek succeeded");
        if (!ok) continue;
        long n = dec_render(d, buf, 512);
        check(n == 512, "seek window length");
        long m = 0;
        for (long i = 0; i < n; i++)
            if (l16(buf, i) != ref[p + i]) m++;
        check(m == 0, "seek window bit-exact");
    }

    /* Seek past the end decodes nothing. */
    check(dec_seek(d, dur + 1.0), "seek past end accepted");
    check(dec_render(d, buf, 256) == 0, "no output past end");

    double probe = dec_probe_duration(adata, asize);
    check(fabs(probe - dur) < 0.01, "probe duration matches");
    dec_close(d);

    /* Truncated/garbage data must not open. */
    check(dec_open("MAC ", 4) == NULL, "rejects truncated APE header");

    free(adata);
    free(rdata);
    printf("   %d checks, %d failures\n", checks, fails);
    printf(fails ? "FAILURES\n" : "ALL PASS\n");
    return fails ? 1 : 0;
}
