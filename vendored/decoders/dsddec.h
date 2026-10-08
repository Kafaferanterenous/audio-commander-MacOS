#ifndef DSDDEC_H
#define DSDDEC_H

#include <stddef.h>
#include <stdint.h>

typedef struct dsd_dec {
    const uint8_t *data;
    size_t size;
    size_t pos;
    int is_dsf; /* 1 if DSF (Sony), 0 if DFF (Philips/DSDIFF) */
    int channels;
    int64_t sample_count; /* DSD samples per channel */
    int dsd_rate; /* samples/sec per channel (e.g. 2822400 for DSD64) */
    double pcm_rate; /* output rate */
    int64_t out_frames_total; /* total PCM frames */
    int64_t out_pos; /* current PCM frame position */
    /* decimation state */
    double *buf; /* interleaved float buffer for current block */
    size_t buf_cap;
    size_t buf_len;
    size_t buf_read;
    int64_t dsd_pos; /* current DSD sample index */
} dsd_dec;

int dsd_is_dsf(const uint8_t *bytes, size_t size);
int dsd_is_dff(const uint8_t *bytes, size_t size);
dsd_dec *dsd_open(const uint8_t *bytes, size_t size);
void dsd_close(dsd_dec *d);
double dsd_duration(dsd_dec *d);
long dsd_render(dsd_dec *d, float *out, long frames);
int dsd_seek(dsd_dec *d, double seconds);

#endif
