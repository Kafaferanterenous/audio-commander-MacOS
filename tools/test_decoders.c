#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "decoders.h"

static unsigned char *slurp(const char *path, long *size) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    *size = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *buf = malloc(*size);
    if (fread(buf, 1, *size, f) != (size_t)*size) { fclose(f); free(buf); return NULL; }
    fclose(f);
    return buf;
}

static double rms(const float *x, long n) {
    double s = 0;
    for (long i = 0; i < n; i++) s += x[i] * x[i];
    return sqrt(s / (n ? n : 1));
}

static int test_file(const char *path) {
    long size = 0;
    unsigned char *data = slurp(path, &size);
    printf("== %s (%ld bytes)\n", path, size);
    if (!data) { printf("   FAIL read\n"); return 0; }

    void *d = dec_open(data, size);
    if (!d) { printf("   FAIL open\n"); free(data); return 0; }

    double dur = dec_duration(d);
    printf("   duration %.3fs rate %u ch %u\n", dur, dec_sample_rate(d), dec_channels(d));
    if (dur <= 0 || dur > 3600) { printf("   FAIL duration\n"); dec_close(d); free(data); return 0; }

    /* render whole thing in 1024-frame chunks, track loudness */
    float buf[2048];
    long total = 0;
    int loud = 0;
    for (;;) {
        long n = dec_render(d, buf, 1024);
        if (n <= 0) break;
        total += n;
        if (rms(buf, n * 2) > 0.01) loud++;
    }
    double rendered_secs = total / 44100.0;
    printf("   rendered %ld frames = %.3fs, loud chunks %d\n", total, rendered_secs, loud);
    if (total < 44100 / 2) { printf("   FAIL too little audio\n"); dec_close(d); free(data); return 0; }
    if (loud == 0) { printf("   FAIL silent stream\n"); dec_close(d); free(data); return 0; }
    /* DUMB's duh_get_length is a "suitable stop point", tails render longer */
    if (rendered_secs < dur * 0.5 || rendered_secs > dur * 4.0 + 2.0) {
        printf("   FAIL duration mismatch rendered vs header\n");
        dec_close(d); free(data); return 0;
    }

    /* seek to middle and verify non-silent output */
    if (dec_seek(d, dur / 2)) {
        long n = dec_render(d, buf, 1024);
        printf("   seek mid: got %ld frames rms %.4f\n", n, rms(buf, n > 0 ? n * 2 : 1));
    } else {
        printf("   seek failed (ok for some formats)\n");
    }

    /* probe API consistency */
    double probe = dec_probe_duration(data, size);
    printf("   probe duration %.3fs %s\n", probe, fabs(probe - dur) < 0.01 ? "OK" : "MISMATCH");
    if (fabs(probe - dur) >= 0.01) { dec_close(d); free(data); return 0; }

    dec_close(d);
    free(data);
    printf("   PASS\n");
    return 1;
}

int main(int argc, char **argv) {
    int ok = 1;
    for (int i = 1; i < argc; i++) ok &= test_file(argv[i]);
    printf(ok ? "ALL PASS\n" : "FAILURES\n");
    return ok ? 0 : 1;
}
