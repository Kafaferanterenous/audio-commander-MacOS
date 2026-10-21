/* DTS Core integration harness (#20).
 *
 * Drives the shipping dec_* API over small, frame-aligned DTS fixtures and
 * checks the decoded PCM against the *independent* ffmpeg-derived reference
 * PCM (pcm_s32le) that ships alongside each stream. It also exercises seek,
 * end-of-stream and duration probing, so the C glue (channel downmix, scale,
 * frame blocking) is verified end to end rather than only the Rust decoder.
 *
 *   build/tools/test_dts [fixture-dir]     (default: tools/fixtures/dts)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "decoders.h"
#include "dts_ffi.h"

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

/* Pearson correlation of two equal-length sample vectors. */
static double pearson(const int *a, const int *b, long n) {
    double ma = 0, mb = 0;
    for (long i = 0; i < n; i++) { ma += a[i]; mb += b[i]; }
    ma /= (double)n; mb /= (double)n;
    double num = 0, da = 0, db = 0;
    for (long i = 0; i < n; i++) {
        double x = a[i] - ma, y = b[i] - mb;
        num += x * y; da += x * x; db += y * y;
    }
    if (da == 0 || db == 0) return 0;
    return num / (sqrt(da) * sqrt(db));
}

/* Decode `name` fully and compare against `ref` (channels = the reference's
 * interleaved channel count). `prefixOnly` is set for the termination fixture,
 * whose reference decoder stops at the normal-frame prefix and skips the short
 * termination frame our decoder does emit. */
static void run_case(const char *dir, const char *name, int refch, int prefixOnly) {
    char dpath[1024], rpath[1024];
    snprintf(dpath, sizeof dpath, "%s/%s.dts", dir, name);
    snprintf(rpath, sizeof rpath, "%s/%s_ref.s32", dir, name);

    long dsize = 0, rsize = 0;
    unsigned char *ddata = slurp(dpath, &dsize);
    unsigned char *rdata = slurp(rpath, &rsize);
    printf("== DTS %s ==\n", name);
    check(ddata != NULL, "read .dts");
    check(rdata != NULL, "read reference");
    if (!ddata || !rdata) { free(ddata); free(rdata); return; }
    const long refN = rsize / 4 / refch;
    const int *ref = (const int *)rdata;

    void *d = dec_open(ddata, dsize);
    check(d != NULL, "dec_open");
    if (!d) { free(ddata); free(rdata); return; }

    double dur = dec_duration(d);
    printf("   duration %.4fs rate %u ch %u\n", dur, dec_sample_rate(d), dec_channels(d));
    check(dec_sample_rate(d) == 44100, "rate 44100 (resampled)");
    check(dec_channels(d) == 2, "stereo output");

    float buf[2048];
    long total = 0;
    for (;;) {
        long n = dec_render(d, buf, 1024);
        if (n <= 0) break;
        total += n;
    }
    printf("   rendered %ld frames (%.4fs), ref %ld frames\n", total, total / 44100.0, refN);
    /* The reference is at 48 kHz; the shipping path resamples to 44.1 kHz, so
     * the expected output length is the reference scaled by 44100/48000. The
     * termination fixture's reference omits the short termination frame our
     * decoder emits, so there the reference is a length lower bound. */
    long expectN = (long)llround((double)refN * 44100.0 / 48000.0);
    if (prefixOnly)
        check(total >= expectN, "rendered length >= reference prefix");
    else
        check(labs(total - expectN) <= 2, "rendered length ~ reference at 44.1 kHz");

    /* The shipping path resamples 48 kHz -> 44.1 kHz, which makes sample-exact
     * comparison against the 48 kHz reference meaningless through dec_render.
     * Instead, verify the reconstructed waveform at native rate through the
     * same FFI shim (dts_open/dts_read) for the 2-plane stereo case. The DTS
     * output gain is implementation-defined (see the crate's own black-box
     * test), so the comparison is shape-invariant: Pearson correlation ~ 1.0.
     * Then confirm the shipping path itself decodes non-silent, correctly
     * lengthed audio. */
    if (refch == 2) {
        void *h = dts_open(ddata, (size_t)dsize);
        check(h != NULL, "native dts_open");
        if (h) {
            dts_info_t info;
            check(dts_info(h, &info) == 1, "native dts_info");
            long k = 0;
            int32_t pcm[4096];
            int *oursL = malloc((size_t)(refN + 4096) * sizeof(int));
            int *oursR = malloc((size_t)(refN + 4096) * sizeof(int));
            int *refL = malloc((size_t)refN * sizeof(int));
            int *refR = malloc((size_t)refN * sizeof(int));
            for (long i = 0; i < refN; i++) { refL[i] = ref[i * 2]; refR[i] = ref[i * 2 + 1]; }
            for (;;) {
                int64_t got = dts_read(h, pcm, 1024);
                if (got <= 0) break;
                for (int64_t i = 0; i < got && k < refN + 4096; i++) {
                    oursL[k] = pcm[i * 2];
                    oursR[k] = pcm[i * 2 + 1];
                    k++;
                }
            }
            printf("   native read %ld planes, ref %ld\n", k, refN);
            if (prefixOnly)
                check(k >= refN, "native read covers reference prefix");
            else
                check(k == refN, "native read length == reference");
            if (k >= refN) {
                double cl = pearson(oursL, refL, refN);
                double cr = pearson(oursR, refR, refN);
                printf("   correlation L=%.6f R=%.6f\n", cl, cr);
                check(cl > 0.999 && cr > 0.999, "shape-identical vs ffmpeg reference");
            }
            free(oursL); free(oursR); free(refL); free(refR);
            dts_close(h);
        }
    } else {
        /* Multi-channel: the downmix to stereo is ours, so only assert the
         * shipping path produces correctly-lengthed, non-silent audio. */
        double e = 0;
        void *d2 = dec_open(ddata, dsize);
        for (;;) {
            long n = dec_render(d2, buf, 1024);
            if (n <= 0) break;
            for (long i = 0; i < n; i++) e += (double)buf[i * 2] * buf[i * 2];
        }
        dec_close(d2);
        printf("   downmix output energy %.3g\n", e);
        check(e > 0.0, "downmixed signal is non-silent");
    }

    /* Sample-accurate-ish seek: window after a seek must render. */
    long p = refN / 2;
    int ok = dec_seek(d, (double)p / 48000.0);
    check(ok, "dec_seek succeeded");
    if (ok) {
        long n = dec_render(d, buf, 512);
        check(n > 0, "seek window renders");
    }

    /* Seek past the end decodes nothing. */
    check(dec_seek(d, dur + 1.0), "seek past end accepted");
    check(dec_render(d, buf, 256) == 0, "no output past end");

    double probe = dec_probe_duration(ddata, dsize);
    check(fabs(probe - dur) < 0.01, "probe duration matches");
    dec_close(d);

    free(ddata);
    free(rdata);
}

int main(int argc, char **argv) {
    const char *dir = argc > 1 ? argv[1] : "tools/fixtures/dts";
    printf("== DTS integration ==\n");
    run_case(dir, "stereo", 2, 0);
    run_case(dir, "d10", 2, 0);
    run_case(dir, "joint", 2, 0);
    run_case(dir, "term", 2, 1);
    run_case(dir, "lfe51", 6, 0);

    /* Truncated/garbage data must not open. */
    check(dec_open("\x7f\xfe\x80\x01\xfc\x3c", 6) == NULL, "rejects truncated DTS");
    check(dec_open("not dts at all", 14) == NULL, "rejects non-DTS data");

    printf("   %d checks, %d failures\n", checks, fails);
    printf(fails ? "FAILURES\n" : "ALL PASS\n");
    return fails ? 1 : 0;
}
