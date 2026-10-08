#include "dsddec.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define OUT_RATE 44100.0

/* Very simple DSD->PCM decimation: low-pass + sample rate conversion by averaging
   For DSD64 (2.8224MHz), decimating by 64 gives 44.1kHz. This is a naive but
   functional approach sufficient for playback - better filters could be added later.
*/

/* Parse DSF (Sony) format */
static int dsd_open_dsf(dsd_dec *d, const uint8_t *bytes, size_t size) {
    if (size < 92) return 0;
    /* 'DSD ' chunk at start */
    if (memcmp(bytes, "DSD ", 4) != 0) return 0;
    uint64_t chunk_size = 0;
    /* read chunk size (little endian) at offset 4 */
    for (int i = 0; i < 8; i++) {
        chunk_size |= ((uint64_t)bytes[4 + i]) << (i * 8);
    }
    if (chunk_size > size) return 0;
    /* 'fmt ' at offset 28? typical DSF layout: DSD chunk (28 bytes total), then fmt chunk */
    /* fmt chunk starts at 28: 'fmt ' (4) + size (4) + format (2) + channels (2) + sample rate (4) + ... */
    if (size < 36 || memcmp(bytes + 28, "fmt ", 4) != 0) return 0;
    uint32_t fmt_size = bytes[32] | (bytes[33] << 8) | (bytes[34] << 16) | (bytes[35] << 24);
    if (size < 28 + 12 + fmt_size) return 0;
    size_t fmt_off = 28 + 8;
    /* format version 1: bytes at fmt_off: format (2), channels (2), rate (4) */
    uint16_t format = bytes[fmt_off] | (bytes[fmt_off + 1] << 8);
    uint16_t channels = bytes[fmt_off + 2] | (bytes[fmt_off + 3] << 8);
    uint32_t rate = bytes[fmt_off + 4] | (bytes[fmt_off + 5] << 8) | (bytes[fmt_off + 6] << 16) | (bytes[fmt_off + 7] << 24);
    if (channels < 1 || channels > 8 || rate == 0) return 0;
    /* find data chunk 'data' */
    size_t p = 28 + 12 + fmt_size;
    while (p + 12 <= size) {
        if (memcmp(bytes + p, "data", 4) == 0) {
            uint64_t data_size = 0;
            for (int i = 0; i < 8; i++) {
                data_size |= ((uint64_t)bytes[p + 4 + i]) << (i * 8);
            }
            size_t data_start = p + 12;
            if (data_start + data_size <= size || data_start < size) {
                d->is_dsf = 1;
                d->channels = channels;
                d->dsd_rate = rate;
                d->sample_count = (data_size * 8) / channels; /* DSD bits / channels */
                d->data = bytes;
                d->size = size;
                d->pos = data_start;
                d->out_frames_total = (d->sample_count * (int64_t)OUT_RATE) / d->dsd_rate;
                if (d->out_frames_total < 0) d->out_frames_total = 0;
                d->out_pos = 0;
                d->buf_cap = 0;
                d->buf_len = 0;
                d->buf_read = 0;
                d->buf = NULL;
                return 1;
            }
        }
        /* skip chunk: read chunk size at p+4 */
        if (p + 8 > size) break;
        uint64_t csz = 0;
        for (int i = 0; i < 8; i++) {
            csz |= ((uint64_t)bytes[p + 4 + i]) << (i * 8);
        }
        p += 12 + (size_t)csz;
        if (csz == 0) break;
    }
    return 0;
}

static int dsd_open_dff(dsd_dec *d, const uint8_t *bytes, size_t size) {
    if (size < 12) return 0;
    if (memcmp(bytes, "FRM8", 4) != 0) return 0;
    /* FRM8 chunk size */
    uint32_t frm_size = bytes[4] | (bytes[5] << 8) | (bytes[6] << 16) | (bytes[7] << 24);
    if (memcmp(bytes + 8, "DSD ", 4) != 0) return 0;
    /* look for FVER, PROP, SND */
    size_t p = 12;
    uint32_t rate = 2822400; /* default DSD64 */
    uint16_t channels = 2;
    size_t data_start = 0;
    uint64_t data_size = 0;
    while (p + 8 <= size) {
        const uint8_t *id = bytes + p;
        uint32_t csz = bytes[p + 4] | (bytes[p + 5] << 8) | (bytes[p + 6] << 16) | (bytes[p + 7] << 24);
        if (memcmp(id, "FVER", 4) == 0) {
            /* skip */
        } else if (memcmp(id, "PROP", 4) == 0) {
            /* look inside PROP for SND */
        } else if (memcmp(id, "SND ", 4) == 0) {
            /* SND chunk: skip 8 bytes (SND + size) then find 'DSD ' data */
            data_start = p + 12;
            data_size = csz;
            if (data_start + data_size > size) {
                data_size = size > data_start ? (size - data_start) : 0;
            }
        } else if (memcmp(id, "FS  ", 4) == 0 || memcmp(id, "FS ", 3) == 0) {
            /* sample rate */
            if (p + 12 <= size) {
                rate = bytes[p + 8] | (bytes[p + 9] << 8) | (bytes[p + 10] << 16) | (bytes[p + 11] << 24);
            }
        } else if (memcmp(id, "CHNL", 4) == 0) {
            if (p + 10 <= size) {
                channels = bytes[p + 8] | (bytes[p + 9] << 8);
            }
        }
        p += 8 + csz;
        if (p > size) break;
    }
    if (data_start == 0 || data_size == 0) return 0;
    d->is_dsf = 0;
    d->channels = channels;
    d->dsd_rate = rate;
    d->sample_count = (data_size * 8) / channels;
    d->data = bytes;
    d->size = size;
    d->pos = data_start;
    d->out_frames_total = (d->sample_count * (int64_t)OUT_RATE) / d->dsd_rate;
    if (d->out_frames_total < 0) d->out_frames_total = 0;
    d->out_pos = 0;
    return 1;
}

dsd_dec *dsd_open(const uint8_t *bytes, size_t size) {
    if (!bytes || size < 4) return NULL;
    dsd_dec *d = calloc(1, sizeof(dsd_dec));
    if (!d) return NULL;
    if (dsd_is_dsf(bytes, size) && dsd_open_dsf(d, bytes, size)) {
        return d;
    }
    if (dsd_is_dff(bytes, size) && dsd_open_dff(d, bytes, size)) {
        return d;
    }
    free(d);
    return NULL;
}

void dsd_close(dsd_dec *d) {
    if (!d) return;
    free(d->buf);
    free(d);
}

double dsd_duration(dsd_dec *d) {
    if (!d || d->dsd_rate == 0) return 0.0;
    return (double)d->sample_count / (double)d->dsd_rate;
}

int dsd_is_dsf(const uint8_t *bytes, size_t size) {
    return size >= 4 && memcmp(bytes, "DSD ", 4) == 0;
}

int dsd_is_dff(const uint8_t *bytes, size_t size) {
    return size >= 12 && memcmp(bytes, "FRM8", 4) == 0 && memcmp(bytes + 8, "DSD ", 4) == 0;
}

long dsd_render(dsd_dec *d, float *out, long frames) {
    if (!d || !out || frames <= 0) return 0;
    long produced = 0;
    double ratio = (double)d->dsd_rate / OUT_RATE;
    int decim = (int)round(ratio);
    if (decim < 1) decim = 64;
    for (long f = 0; f < frames; f++) {
        if (d->out_pos >= d->out_frames_total) break;
        /* average next decim DSD samples for each channel */
        double l = 0, r = 0;
        int got = 0;
        for (int i = 0; i < decim && d->dsd_pos < d->sample_count; i++) {
            /* read bits for channels */
            size_t bit_off = (size_t)(d->dsd_pos * d->channels);
            size_t byte_off = d->pos + bit_off / 8;
            int bit = (bit_off % 8);
            if (byte_off < d->size) {
                uint8_t b = d->data[byte_off];
                /* DSF is LSB first? or just read bit; treat 1 as +1, 0 as -1 for delta-sigma */
                int val_l = ((b >> bit) & 1) ? 1 : -1;
                l += val_l;
                if (d->channels > 1) {
                    size_t byte_off_r = byte_off + (bit_off % 8 + 1 >= 8 ? 1 : 0); /* rough */
                    /* simpler: read channel 0 and 1 in order */
                }
                got++;
            }
            d->dsd_pos++;
        }
        /* better handling for stereo */
        l = 0; r = 0;
        d->dsd_pos -= got;
        for (int i = 0; i < decim && d->dsd_pos < d->sample_count; i++) {
            size_t bit_off = (size_t)(d->dsd_pos * d->channels);
            size_t byte_off = d->pos + bit_off / 8;
            int bit = bit_off % 8;
            if (byte_off < d->size) {
                uint8_t b = d->data[byte_off];
                int bit0 = (b >> (bit % 8)) & 1;
                l += bit0 ? 0.5 : -0.5;
                if (d->channels >= 2) {
                    size_t bit1_off = bit_off + 1;
                    size_t byte1_off = d->pos + bit1_off / 8;
                    int bit1 = bit1_off % 8;
                    if (byte1_off < d->size) {
                        uint8_t b1 = d->data[byte1_off];
                        int v1 = (b1 >> bit1) & 1;
                        r += v1 ? 0.5 : -0.5;
                    }
                } else {
                    r = l;
                }
            }
            d->dsd_pos++;
        }
        l /= decim;
        r /= decim;
        out[f * 2] = (float)l;
        out[f * 2 + 1] = (float)r;
        produced++;
        d->out_pos++;
    }
    return produced;
}

int dsd_seek(dsd_dec *d, double seconds) {
    if (!d || d->dsd_rate == 0 || seconds < 0) return 0;
    int64_t target_dsd = (int64_t)(seconds * (double)d->dsd_rate);
    if (target_dsd > d->sample_count) target_dsd = d->sample_count;
    if (target_dsd < 0) target_dsd = 0;
    d->dsd_pos = target_dsd;
    d->out_pos = (target_dsd * (int64_t)OUT_RATE) / d->dsd_rate;
    return 1;
}

int dsd_is_dsf_ext(const uint8_t *bytes, size_t size) {
    return dsd_is_dsf(bytes, size);
}
