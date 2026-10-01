#include "decoders.h"

#include <stdlib.h>
#include <string.h>

#include "dumb.h"
#include "stb_vorbis.c" /* declarations only (no STB_VORBIS_IMPLEMENTATION here) */
#include "wavpack.h"
#include "FLAC/stream_decoder.h"

#define OUT_RATE 44100
/* DUMB delta_time = 65536 (units/sec) / output rate: fixed-point seconds per
 * output sample. The reciprocal here used to slow tracker playback ~2.2x. */
#define DUMB_DELTA (65536.0f / (float)OUT_RATE)

typedef struct dec_decoder dec_decoder;

enum dec_kind {
    DEC_KIND_NONE = 0,
    DEC_KIND_DUMB,
    DEC_KIND_VORBIS,
    DEC_KIND_VOC,
    DEC_KIND_WAVPACK,
    DEC_KIND_OGGFLAC
};

struct dec_decoder {
    enum dec_kind kind;
    unsigned char *data;
    long size;

    double duration;      /* seconds, <=0 unknown */
    long pos_frames;      /* output frames rendered since open/seek */

    /* DUMB */
    DUH *duh;
    DUH_SIGRENDERER *sr;

    /* Vorbis */
    stb_vorbis *vb;
    int vb_channels;
    unsigned int vb_rate;
    /* streaming linear resampler to OUT_RATE */
    double res_frac;
    float res_prev_l;
    float res_prev_r;
    int res_has_prev;

    /* VOC: fully decoded at open into interleaved stereo f32 @OUT_RATE */
    float *voc_pcm;
    long voc_frames;

    /* WavPack */
    WavpackContext *wv;
    struct wv_mem *wv_src;
    int wv_channels;
    unsigned int wv_rate;
    int wv_is_float;
    int32_t *wv_buf;       /* interleaved int32 scratch, channels * WV_CHUNK */
    long wv_buf_frames;    /* frames currently valid in wv_buf */
    long wv_buf_used;      /* frames already consumed from wv_buf */

    /* Ogg FLAC (libFLAC + libogg, BSD - vendored under vendored/flac+ogg) */
    struct of_stream *of;
    FLAC__StreamDecoder *of_dec;
    int32_t *of_buf;       /* interleaved int32 staging, of_buf_cap frames */
    long of_buf_cap;       /* capacity in int32 samples */
    long of_buf_frames;    /* frames currently valid in of_buf */
    long of_buf_used;      /* frames already consumed from of_buf */
    int of_channels;
    unsigned int of_rate;
    double of_scale;       /* 1 / full-scale for of_buf's fixed-point samples */
    int of_failed;         /* decoder reported an error / end of stream */
};

/* ------------------------------------------------------------------ */
/* DUMB                                                                */
/* ------------------------------------------------------------------ */

static int dumb_loop_once(void *userdata) {
    (void)userdata;
    return 1; /* break out of loops so looping modules still terminate */
}

static void dumb_start_renderer(dec_decoder *d) {
    if (d->sr) return;
    d->sr = duh_start_sigrenderer(d->duh, 0, 2, 0);
    if (d->sr) {
        DUMB_IT_SIGRENDERER *itsr = duh_get_it_sigrenderer(d->sr);
        if (itsr) dumb_it_set_loop_callback(itsr, dumb_loop_once, NULL);
    }
}

/* ------------------------------------------------------------------ */
/* VOC parser                                                          */
/* ------------------------------------------------------------------ */

static unsigned int voc_read_u24le(const unsigned char *p) {
    return (unsigned int)p[0] | ((unsigned int)p[1] << 8) | ((unsigned int)p[2] << 16);
}

static int voc_grow(float **buf, long *cap, long needed_frames) {
    if (needed_frames <= *cap) return 1;
    long ncap = *cap ? *cap : 65536;
    while (ncap < needed_frames) ncap *= 2;
    float *nbuf = (float *)realloc(*buf, (size_t)ncap * 2 * sizeof(float));
    if (!nbuf) return 0;
    *buf = nbuf;
    *cap = ncap;
    return 1;
}

static int voc_emit(dec_decoder *d, float **buf, long *cap, long *len,
                    float l, float r) {
    if (!voc_grow(buf, cap, *len + 1)) return 0;
    (*buf)[*len * 2] = l;
    (*buf)[*len * 2 + 1] = r;
    (*len)++;
    return 1;
}

/*
 Append a mono chunk (raw PCM) at native `rate` to the output buffer,
 linear-resampling to OUT_RATE. Phase + previous sample carry across
 chunks. codec: 0 = unsigned 8-bit PCM, 3 = signed 16-bit LE PCM.
 Returns number of output frames appended, or -1 on OOM.
*/
static long voc_resample_chunk(float **buf, long *cap, long *len,
                               const unsigned char *raw, long count, int codec,
                               double rate, double *phase, float *prev,
                               int *has_prev) {
    double step = rate / (double)OUT_RATE;
    long emitted = 0;
    long i;
    for (i = 0; i < count; i++) {
        float s;
        if (codec == 3) {
            short v = (short)(raw[i * 2] | (raw[i * 2 + 1] << 8));
            s = v / 32768.0f;
        } else {
            s = (((int)raw[i]) - 128) / 128.0f;
        }
        if (!*has_prev) {
            *prev = s;
            *has_prev = 1;
        }
        double frac = *phase;
        while (frac < 1.0) {
            float out = (float)((*prev) + (s - (*prev)) * frac);
            if (!voc_emit(NULL, buf, cap, len, out, out)) return -1;
            emitted++;
            frac += step;
        }
        frac -= 1.0;
        if (frac < 0) frac = 0;
        *phase = frac;
        *prev = s;
    }
    return emitted;
}

static long voc_resample_adpcm(float **buf, long *cap, long *len, int *idx,
                               int *prev, const unsigned char *data,
                               long bytes, double rate, double *phase,
                               float *prevf, int *has_prev);

static int voc_decode_all(dec_decoder *d) {
    const unsigned char *p = d->data;
    long size = d->size;
    long off;
    float *buf = NULL;
    long cap = 0, len = 0;
    double phase = 0.0;
    float prev = 0.0f;
    int has_prev = 0;
    int adpcm_idx = 0, adpcm_prev = 0;

    if (size < 26 || memcmp(p, "Creative Voice File\x1a", 20) != 0) return 0;
    off = p[20] | (p[21] << 8);
    if (off < 20 || off > size) off = 26;

    while (off + 4 <= size) {
        unsigned char type = p[off];
        if (type == 0) break; /* terminator */
        unsigned long blen = voc_read_u24le(p + off + 1);
        const unsigned char *body = p + off + 4;
        if (off + 4 + (long)blen > size) break;

        switch (type) {
            case 0x01: { /* sound data */
                if (blen < 2) break;
                unsigned char sr_byte = body[0];
                int codec = body[1];
                long count = (long)blen - 2;
                double rate = 1000000.0 / (256 - sr_byte);
                if (codec == 3) count /= 2;
                if (voc_resample_chunk(&buf, &cap, &len, body + 2, count,
                                       codec, rate, &phase, &prev, &has_prev) < 0)
                    goto oom;
                break;
            }
            case 0x02: { /* sound data: 4-bit ADPCM, 8 kHz (Sound Blaster) */
                if (blen < 2) break;
                unsigned char sr_byte = body[0];
                double rate = 1000000.0 / (256 - sr_byte);
                if (voc_resample_adpcm(&buf, &cap, &len, &adpcm_idx,
                                       &adpcm_prev, body + 1, (long)blen - 1,
                                       rate, &phase, &prev, &has_prev) < 0)
                    goto oom;
                break;
            }
            case 0x03: { /* silence */
                if (blen < 3) break;
                unsigned int scount = (unsigned int)(body[0] | (body[1] << 8));
                unsigned char sr_byte = body[2];
                double rate = 1000000.0 / (256 - sr_byte);
                long emitted = voc_resample_chunk(&buf, &cap, &len, NULL, 0,
                                                  0, rate, &phase, &prev,
                                                  &has_prev);
                if (emitted < 0) goto oom;
                /* silence = constant 0; synthesize directly using same step */
                {
                    long i;
                    double step = rate / (double)OUT_RATE;
                    double frac = phase;
                    for (i = 0; i < (long)scount; i++) {
                        while (frac < 1.0) {
                            if (!voc_emit(NULL, &buf, &cap, &len, 0.0f, 0.0f))
                                goto oom;
                            frac += step;
                        }
                        frac -= 1.0;
                    }
                    phase = frac < 0 ? 0 : frac;
                    has_prev = 0; /* discontinuity after gap */
                }
                break;
            }
            case 0x09: case 0x0B: { /* extended format + ADPCM sound data blocks */
                if (blen < 12) break;
                unsigned long datalen = (unsigned long)body[0]
                    | ((unsigned long)body[1] << 8)
                    | ((unsigned long)body[2] << 16)
                    | ((unsigned long)body[3] << 24);
                unsigned int fmt = (unsigned int)(body[4] | (body[5] << 8));
                unsigned int hz = (unsigned int)body[6]
                    | ((unsigned int)body[7] << 8)
                    | ((unsigned int)body[8] << 16)
                    | ((unsigned int)body[9] << 24);
                unsigned char bits = body[10];
                unsigned char chans = body[11];
                if (datalen > blen - 12) datalen = blen - 12;
                if (fmt != 1) break; /* only uncompressed + our ADPCM below */
                if ((bits == 16 || bits == 8) && datalen > 0) {
                    if (chans == 2 && bits == 16 && datalen >= 4) {
                    long frames = (long)datalen / 4;
                    long i;
                    double step = (double)hz / (double)OUT_RATE;
                    for (i = 0; i < frames; i++) {
                        short l = (short)(body[12 + i * 4] | (body[13 + i * 4] << 8));
                        short r = (short)(body[14 + i * 4] | (body[15 + i * 4] << 8));
                        float fl = l / 32768.0f, fr = r / 32768.0f;
                        double frac = phase;
                        while (frac < 1.0) {
                            if (!voc_emit(NULL, &buf, &cap, &len, fl, fr)) goto oom;
                            frac += step;
                        }
                        frac -= 1.0;
                        if (frac < 0) frac = 0;
                        phase = frac;
                    }
                } else if (chans == 2 && bits == 8 && datalen >= 2) {
                    long frames = (long)datalen / 2;
                    long i;
                    double step = (double)hz / (double)OUT_RATE;
                    for (i = 0; i < frames; i++) {
                        float fl = (((int)body[12 + i * 2]) - 128) / 128.0f;
                        float fr = (((int)body[13 + i * 2]) - 128) / 128.0f;
                        double frac = phase;
                        while (frac < 1.0) {
                            if (!voc_emit(NULL, &buf, &cap, &len, fl, fr)) goto oom;
                            frac += step;
                        }
                        frac -= 1.0;
                        if (frac < 0) frac = 0;
                        phase = frac;
                    }
                } else if (datalen > 0) { /* mono via shared resampler */
                    long count = (long)datalen;
                    if (bits == 16) count /= 2;
                    if (voc_resample_chunk(&buf, &cap, &len, body + 12, count,
                                           bits == 16 ? 3 : 0, (double)hz,
                                           &phase, &prev, &has_prev) < 0)
                        goto oom;
                }
            } else if (bits == 4 && chans == 1 && datalen > 0) {
                if (voc_resample_adpcm(&buf, &cap, &len, &adpcm_idx,
                                       &adpcm_prev, body + 12, (long)datalen,
                                       (double)hz, &phase, &prev, &has_prev) < 0)
                    goto oom;
            }
            break;
        }
        default:
                break; /* markers (0x04/0x06/0x07), text blocks: skip */
        }

        off += 4 + (long)blen;
    }

    d->voc_pcm = buf;
    d->voc_frames = len;
    d->duration = (double)len / (double)OUT_RATE;
    return len > 0;

oom:
    free(buf);
    return 0;
}

/* ------------------------------------------------------------------ */
/* VOC 4-bit ADPCM (Creative Labs / Sound Blaster recording format)   */
/* ------------------------------------------------------------------ */

static const short voc_step_tab[49] = {
    16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80,
    88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337,
    371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282,
    1411, 1552
};

static const char voc_index_tab[16] = {
    -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8
};

/* Decode one 4-bit nibble, updating ADPCM state. Returns 16-bit sample. */
static int voc_adpcm4_sample(int *idx, int *prev, unsigned char nib) {
    int s = nib & 0x0F;
    int step = voc_step_tab[*idx];
    int diff = step >> 3;
    if (s & 1) diff += step >> 2;
    if (s & 2) diff += step >> 1;
    if (s & 4) diff += step;
    int sample = (s & 8) ? (*prev - diff) : (*prev + diff);
    if (sample > 32767) sample = 32767;
    if (sample < -32768) sample = -32768;
    *idx += voc_index_tab[s];
    if (*idx < 0) *idx = 0;
    if (*idx > 48) *idx = 48;
    *prev = sample;
    return sample;
}

/* Decode bytes of packed 4-bit ADPCM (2 samples/byte, MSB first) and feed
 * the resulting s16 stream through the shared linear resampler. ADPCM state
 * carries across blocks so a chain of blocks decodes as one stream. */
static long voc_resample_adpcm(float **buf, long *cap, long *len, int *idx,
                               int *prev, const unsigned char *data,
                               long bytes, double rate, double *phase,
                               float *prevf, int *has_prev) {
    if (bytes <= 0) return 0;
    long nsamples = bytes * 2;
    short *smp = (short *)malloc((size_t)nsamples * sizeof(short));
    if (!smp) return -1;
    long k;
    for (k = 0; k < bytes; k++) {
        unsigned char b = data[k];
        smp[k * 2] = (short)voc_adpcm4_sample(idx, prev, b >> 4);
        smp[k * 2 + 1] = (short)voc_adpcm4_sample(idx, prev, b & 0x0F);
    }
    long rc = voc_resample_chunk(buf, cap, len, (const unsigned char *)smp,
                                 nsamples, 3, rate, phase, prevf, has_prev);
    free(smp);
    return rc;
}

/* ------------------------------------------------------------------ */
/* Vorbis                                                              */
/* ------------------------------------------------------------------ */

static long vorbis_fill(dec_decoder *d, float *out, long frames) {
    long filled = 0;
    int direct = (d->vb_rate == OUT_RATE);
    double step = (double)d->vb_rate / (double)OUT_RATE;

    while (filled < frames) {
        float **outputs;
        int nch = 0;
        int got = stb_vorbis_get_frame_float(d->vb, &nch, &outputs);
        if (got <= 0) break;
        long i;
        for (i = 0; i < got && filled < frames; i++) {
            float l, r;
            if (nch >= 2) {
                l = outputs[0][i];
                r = outputs[1][i];
            } else {
                l = r = outputs[0][i];
            }
            if (direct) {
                out[filled * 2] = l;
                out[filled * 2 + 1] = r;
                filled++;
            } else {
                double frac = d->res_frac;
                while (frac < 1.0 && filled < frames) {
                    float pl = d->res_prev_l, pr = d->res_prev_r;
                    if (!d->res_has_prev) { pl = l; pr = r; }
                    out[filled * 2] = (float)(pl + (l - pl) * frac);
                    out[filled * 2 + 1] = (float)(pr + (r - pr) * frac);
                    filled++;
                    frac += step;
                }
                frac -= 1.0;
                if (frac < 0) frac = 0;
                d->res_frac = frac;
                d->res_prev_l = l;
                d->res_prev_r = r;
                d->res_has_prev = 1;
            }
        }
    }
    return filled;
}

/* ------------------------------------------------------------------ */
/* WavPack (libwavpack, BSD 2-clause - vendored under vendored/wavpack) */
/* ------------------------------------------------------------------ */

#define WV_CHUNK 2048  /* frames decoded per library call */

/* Read-only memory block exposed to libwavpack as a WavpackStreamReader, so
   the whole file can be decoded from a mapped Data buffer with no temp file. */
struct wv_mem {
    const unsigned char *data;
    long size;
    long pos;
};

static int32_t wv_read_bytes(void *id, void *data, int32_t bcount) {
    struct wv_mem *r = (struct wv_mem *)id;
    if (bcount < 0) return 0;
    if (r->pos + bcount > r->size) bcount = (int32_t)(r->size - r->pos);
    if (bcount <= 0) return 0;
    memcpy(data, r->data + r->pos, (size_t)bcount);
    r->pos += bcount;
    return bcount;
}

static uint32_t wv_get_pos(void *id) {
    return (uint32_t)((struct wv_mem *)id)->pos;
}

/* NOTE: libwavpack's seek callbacks follow the fseek() convention - they must
   return 0 on SUCCESS and nonzero on failure. Returning 1 on success makes
   every internal find_header() bail out and silently breaks seeking. */
static int wv_set_pos_abs(void *id, uint32_t pos) {
    struct wv_mem *r = (struct wv_mem *)id;
    if ((long)pos > r->size) return 1;
    r->pos = (long)pos;
    return 0;
}

/* mode: 0 = SEEK_SET, 1 = SEEK_CUR, 2 = SEEK_END. Returns 0 on success. */
static int wv_set_pos_rel(void *id, int32_t delta, int mode) {
    struct wv_mem *r = (struct wv_mem *)id;
    long np;
    if (mode == 0) np = delta;
    else if (mode == 2) np = r->size + delta;
    else np = r->pos + delta;
    if (np < 0 || np > r->size) return 1;
    r->pos = np;
    return 0;
}

static int wv_push_back_byte(void *id, int c) {
    struct wv_mem *r = (struct wv_mem *)id;
    if (r->pos <= 0) return 0;
    if (r->data[r->pos - 1] != (unsigned char)c) return 0;
    r->pos--;
    return 1;
}

static uint32_t wv_get_length(void *id) {
    return (uint32_t)((struct wv_mem *)id)->size;
}

static int wv_can_seek(void *id) {
    (void)id;
    return 1;
}

static WavpackStreamReader wv_reader = {
    wv_read_bytes, wv_get_pos, wv_set_pos_abs, wv_set_pos_rel,
    wv_push_back_byte, wv_get_length, wv_can_seek, NULL
};

static int wavpack_open(dec_decoder *d) {
    char err[80];
    struct wv_mem *src = (struct wv_mem *)calloc(1, sizeof(struct wv_mem));
    int32_t *buf = (int32_t *)calloc((size_t)WV_CHUNK * 8, sizeof(int32_t));
    if (!src || !buf) { free(src); free(buf); return 0; }
    src->data = d->data;
    src->size = d->size;
    src->pos = 0;

    WavpackContext *wpc = WavpackOpenFileInputEx(&wv_reader, src, NULL, err,
                                                  OPEN_WRAPPER, 0);
    if (!wpc) { free(src); free(buf); return 0; }

    int channels = WavpackGetNumChannels(wpc);
    unsigned int rate = WavpackGetSampleRate(wpc);
    if (channels < 1 || rate == 0) { WavpackCloseFile(wpc); free(src); free(buf); return 0; }

    int64_t total = WavpackGetNumSamples64(wpc);
    if (total > 0) d->duration = (double)total / (double)rate;

    d->kind = DEC_KIND_WAVPACK;
    d->wv = wpc;
    d->wv_src = src;
    d->wv_channels = channels;
    d->wv_rate = rate;
    d->wv_is_float = (WavpackGetMode(wpc) & MODE_FLOAT) ? 1 : 0;
    d->wv_buf = buf;
    d->wv_buf_frames = 0;
    d->wv_buf_used = 0;
    return 1;
}

/* Packs `frames` interleaved int32 into the scratch buffer, refilling it when
   exhausted. Returns 0 at end of stream. */
static long wavpack_ensure(dec_decoder *d, long frames) {
    if (d->wv_buf_used < d->wv_buf_frames) {
        long avail = d->wv_buf_frames - d->wv_buf_used;
        return avail < frames ? avail : frames;
    }
    uint32_t want = (uint32_t)(frames < WV_CHUNK ? frames : WV_CHUNK);
    uint32_t got = WavpackUnpackSamples(d->wv, d->wv_buf, want);
    d->wv_buf_frames = (long)got;
    d->wv_buf_used = 0;
    return got < frames ? (long)got : frames;
}

/* One interleaved int32 sample -> normalized f32. WavPack hands back IEEE
   float in the same int32 slot; fixed point arrives at whatever scale the
   container documents, hence the explicit `scale` (1 / full-scale-value). */
static float pcm_value(int32_t raw, int is_float, double scale) {
    if (is_float) {
        float f;
        memcpy(&f, &raw, sizeof(f));
        if (f > 1.0f) f = 1.0f;
        if (f < -1.0f) f = -1.0f;
        return f;
    }
    return (float)(((double)raw) * scale);
}

/* Converts up to `have` frames of interleaved int32 `src` (`nch` channels at
   `rate`) into `out` as stereo @OUT_RATE, downmixing to the first two channels
   and running the shared linear resampler when the rates differ. `*filled` is
   the caller's in/out output frame count; returns source frames consumed. */
static long pcm_to_stereo(dec_decoder *d, const int32_t *src, int nch,
                          int is_float, double scale, unsigned int rate,
                          long have, float *out, long cap, long *filled) {
    int direct = (rate == OUT_RATE);
    double step = (double)rate / (double)OUT_RATE;
    long i;

    for (i = 0; i < have && *filled < cap; i++) {
        const int32_t *frame = src + i * nch;
        float l, r;
        if (nch >= 2) {
            l = pcm_value(frame[0], is_float, scale);
            r = pcm_value(frame[1], is_float, scale);
        } else {
            l = r = pcm_value(frame[0], is_float, scale);
        }
        if (direct) {
            out[*filled * 2] = l;
            out[*filled * 2 + 1] = r;
            (*filled)++;
        } else {
            double frac = d->res_frac;
            while (frac < 1.0 && *filled < cap) {
                float pl = d->res_prev_l, pr = d->res_prev_r;
                if (!d->res_has_prev) { pl = l; pr = r; }
                out[*filled * 2] = (float)(pl + (l - pl) * frac);
                out[*filled * 2 + 1] = (float)(pr + (r - pr) * frac);
                (*filled)++;
                frac += step;
            }
            frac -= 1.0;
            if (frac < 0) frac = 0;
            d->res_frac = frac;
            d->res_prev_l = l;
            d->res_prev_r = r;
            d->res_has_prev = 1;
        }
    }
    return i;
}

/* Renders up to `frames` stereo @OUT_RATE frames, resampling and downmixing
   as needed. Shares the linear resampler state with the Vorbis path; only one
   kind is ever active per decoder. */
static long wavpack_fill(dec_decoder *d, float *out, long frames) {
    long filled = 0;
    while (filled < frames) {
        long have = wavpack_ensure(d, frames - filled);
        if (have <= 0) break;
        long used = pcm_to_stereo(d, d->wv_buf + d->wv_buf_used * d->wv_channels,
                                  d->wv_channels, d->wv_is_float,
                                  1.0 / 2147483648.0, d->wv_rate, have, out,
                                  frames, &filled);
        if (used <= 0) break;
        d->wv_buf_used += used;
    }
    return filled;
}

/* ------------------------------------------------------------------ */
/* Ogg FLAC (libFLAC + libogg, BSD/Xiph - vendored under vendored/flac, */
/* vendored/ogg). libFLAC owns the Ogg framing, so only the raw file     */
/* bytes are exposed to it as a read-only memory stream.                  */
/* ------------------------------------------------------------------ */

struct of_stream {
    const unsigned char *data;
    long size;
    long pos;
    dec_decoder *d;        /* NULL until the decoder is fully accepted */
    FLAC__uint64 total;    /* STREAMINFO total samples, 0 = unknown */
    unsigned int rate;     /* STREAMINFO sample rate */
    unsigned int bps;      /* STREAMINFO bits per sample */
    int channels;          /* STREAMINFO channel count */
};

static FLAC__StreamDecoderReadStatus of_read(const FLAC__StreamDecoder *dec,
                                             FLAC__byte buf[], size_t *bytes,
                                             void *cd) {
    struct of_stream *s = (struct of_stream *)cd;
    size_t want = *bytes;
    if (s->pos >= s->size) {
        *bytes = 0;
        return FLAC__STREAM_DECODER_READ_STATUS_END_OF_STREAM;
    }
    if ((size_t)(s->size - s->pos) < want) want = (size_t)(s->size - s->pos);
    memcpy(buf, s->data + s->pos, want);
    s->pos += (long)want;
    *bytes = want;
    return FLAC__STREAM_DECODER_READ_STATUS_CONTINUE;
}

static FLAC__StreamDecoderSeekStatus of_seek(const FLAC__StreamDecoder *dec,
                                             FLAC__uint64 abs, void *cd) {
    struct of_stream *s = (struct of_stream *)cd;
    (void)dec;
    if (abs > (FLAC__uint64)s->size) return FLAC__STREAM_DECODER_SEEK_STATUS_ERROR;
    s->pos = (long)abs;
    return FLAC__STREAM_DECODER_SEEK_STATUS_OK;
}

static FLAC__StreamDecoderTellStatus of_tell(const FLAC__StreamDecoder *dec,
                                             FLAC__uint64 *abs, void *cd) {
    struct of_stream *s = (struct of_stream *)cd;
    (void)dec;
    *abs = (FLAC__uint64)s->pos;
    return FLAC__STREAM_DECODER_TELL_STATUS_OK;
}

static FLAC__StreamDecoderLengthStatus of_length(const FLAC__StreamDecoder *dec,
                                                 FLAC__uint64 *len, void *cd) {
    struct of_stream *s = (struct of_stream *)cd;
    (void)dec;
    *len = (FLAC__uint64)s->size;
    return FLAC__STREAM_DECODER_LENGTH_STATUS_OK;
}

static FLAC__bool of_eof(const FLAC__StreamDecoder *dec, void *cd) {
    struct of_stream *s = (struct of_stream *)cd;
    (void)dec;
    return s->pos >= s->size ? true : false;
}

/* Grows the interleaved staging buffer so it can hold `frames` frames of
   `nch` channels. */
static int of_reserve(dec_decoder *d, long frames, int nch) {
    long need = frames * nch;
    if (need <= d->of_buf_cap) return 1;
    long cap = d->of_buf_cap ? d->of_buf_cap : (long)nch * 4096;
    while (cap < need) cap *= 2;
    int32_t *p = (int32_t *)realloc(d->of_buf, (size_t)cap * sizeof(int32_t));
    if (!p) return 0;
    d->of_buf = p;
    d->of_buf_cap = cap;
    return 1;
}

static FLAC__StreamDecoderWriteStatus of_write(const FLAC__StreamDecoder *dec,
                                                const FLAC__Frame *frame,
                                                const FLAC__int32 *const buf[],
                                                void *cd) {
    struct of_stream *s = (struct of_stream *)cd;
    dec_decoder *d = s->d;
    (void)dec;
    if (!d) return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    long bs = (long)frame->header.blocksize;
    int nch = (int)frame->header.channels;
    long base = d->of_buf_used;   /* append after anything still pending */
    /* libFLAC hands out samples right-justified to the file's bit depth, so
     * the full-scale value is 2^(bps-1) - not 2^31 as for WavPack. A frame
     * header of 0 means "same as STREAMINFO". */
    {
        unsigned int bps = frame->header.bits_per_sample ? frame->header.bits_per_sample : s->bps;
        d->of_scale = (bps >= 1 && bps <= 32) ? scalbn(1.0, -(int)(bps - 1)) : (1.0 / 2147483648.0);
    }
    if (nch < 1 || bs < 1) return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
    if (!of_reserve(d, base + bs, nch)) return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    {
        long i;
        int c;
        for (i = 0; i < bs; i++) {
            int32_t *dst = d->of_buf + (base + i) * nch;
            for (c = 0; c < nch; c++) dst[c] = buf[c][i];
        }
    }
    d->of_buf_frames = base + bs;
    d->of_channels = nch;
    return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
}

/* libFLAC only publishes sample_rate/channels/blocksize to its getters once the
   first AUDIO frame has been decoded (stream_decoder.c copies them out of the
   frame header), so STREAMINFO is the only source available at open time. */
static void of_metadata(const FLAC__StreamDecoder *dec,
                        const FLAC__StreamMetadata *meta, void *cd) {
    struct of_stream *s = (struct of_stream *)cd;
    (void)dec;
    if (meta->type == FLAC__METADATA_TYPE_STREAMINFO) {
        s->total = meta->data.stream_info.total_samples;
        s->rate = meta->data.stream_info.sample_rate;
        s->bps = meta->data.stream_info.bits_per_sample;
        s->channels = (int)meta->data.stream_info.channels;
    }
}

static void of_error(const FLAC__StreamDecoder *dec,
                     FLAC__StreamDecoderErrorStatus status, void *cd) {
    struct of_stream *s = (struct of_stream *)cd;
    (void)dec;
    (void)status;
    if (s->d) s->d->of_failed = 1;
}

static void oggflac_teardown(dec_decoder *d) {
    if (d->of_dec) {
        FLAC__stream_decoder_finish(d->of_dec);
        FLAC__stream_decoder_delete(d->of_dec);
        d->of_dec = NULL;
    }
    if (d->of) {
        d->of->d = NULL;   /* no callback may touch d after this point */
        free(d->of);
        d->of = NULL;
    }
    free(d->of_buf);
    d->of_buf = NULL;
    d->of_buf_cap = 0;
    d->of_buf_frames = 0;
    d->of_buf_used = 0;
}

/* The Ogg "identification" packet is page 0, always uncompressed. libFLAC's Ogg
   encoder repacketizes the native FLAC stream verbatim, so page 0 holds exactly
   one segment whose payload starts with the FLAC magic:
     0..3 "OggS"  4 version(0)  5 header type  6..13 granule
     14..17 serial  18..21 seq  22..25 CRC     26 segment count N
     27..27+N-1 segment table, packet body at 27+N
   Both encodings of that first packet are accepted: the native magic libFLAC
   writes (0x7F "FLAC") and the Xiph mapping header ("\x01FLAC"). Cheap enough to
   run before the stb_vorbis open (whole-file copy + hash table) so .oga never
   pays for a decoder it will not use. */
static int ogg_is_flac(const unsigned char *bytes, size_t size) {
    unsigned n;
    size_t start;
    if (size < 32) return 0;
    if (memcmp(bytes, "OggS", 4) != 0 || bytes[4] != 0x00) return 0;
    n = bytes[26];
    if (n < 1 || n > 16) return 0;           /* a single small id packet */
    start = 27u + n;
    if (start + 5 > size) return 0;
    return memcmp(bytes + start, "\x7f" "FLAC", 5) == 0
        || memcmp(bytes + start, "\x01" "FLAC", 5) == 0;
}

static int oggflac_open(dec_decoder *d) {
    struct of_stream *s = (struct of_stream *)calloc(1, sizeof(struct of_stream));
    FLAC__StreamDecoder *dec = FLAC__stream_decoder_new();
    if (!s || !dec) {
        free(s);
        if (dec) FLAC__stream_decoder_delete(dec);
        return 0;
    }
    s->data = d->data;
    s->size = d->size;
    s->pos = 0;

    if (FLAC__stream_decoder_init_ogg_stream(dec, of_read, of_seek, of_tell,
                                             of_length, of_eof, of_write,
                                             of_metadata, of_error, s)
        != FLAC__STREAM_DECODER_INIT_STATUS_OK) {
        FLAC__stream_decoder_delete(dec);
        free(s);
        return 0;
    }
    if (!FLAC__stream_decoder_process_until_end_of_metadata(dec)
        || s->rate == 0 || s->channels < 1) {
        FLAC__stream_decoder_finish(dec);
        FLAC__stream_decoder_delete(dec);
        free(s);
        return 0;
    }
    if (s->total == 0) s->total = FLAC__stream_decoder_get_total_samples(dec);

    d->kind = DEC_KIND_OGGFLAC;
    d->of = s;
    d->of_dec = dec;
    d->of_channels = s->channels;
    d->of_rate = s->rate;
    d->of_failed = 0;
    s->d = d;
    if (s->total > 0) d->duration = (double)s->total / (double)d->of_rate;
    return 1;
}

/* Renders up to `frames` stereo @OUT_RATE frames, pulling one FLAC frame at a
   time and pushing it through the shared resampler. */
static long oggflac_fill(dec_decoder *d, float *out, long frames) {
    long filled = 0;
    int idle = 0;

    while (filled < frames) {
        if (d->of_buf_used >= d->of_buf_frames) {
            if (!d->of_dec || d->of_failed) break;
            if (!FLAC__stream_decoder_process_single(d->of_dec)) {
                d->of_failed = 1;   /* clean end of stream */
                break;
            }
            if (d->of_buf_used >= d->of_buf_frames && ++idle > 8) break;
            continue;
        }
        idle = 0;
        {
            int nch = d->of_channels;
            long have = d->of_buf_frames - d->of_buf_used;
            long used = pcm_to_stereo(d, d->of_buf + d->of_buf_used * nch,
                                      nch, 0, d->of_scale, d->of_rate, have,
                                      out, frames, &filled);
            if (used <= 0) break;
            d->of_buf_used += used;
        }
    }
    return filled;
}

/* ------------------------------------------------------------------ */
/* Unified API                                                         */
/* ------------------------------------------------------------------ */

void *dec_open(const void *data, size_t size) {
    const unsigned char *bytes = (const unsigned char *)data;
    dec_decoder *d = (dec_decoder *)calloc(1, sizeof(dec_decoder));
    if (!d) return NULL;
    d->data = (unsigned char *)malloc(size ? size : 1);
    if (!d->data) { free(d); return NULL; }
    memcpy(d->data, data, size);
    d->size = (long)size;

    if (size >= 4 && memcmp(bytes, "OggS", 4) == 0) {
        int err = 0;
        /* Fast path: the mapping sniff is exact for anything libFLAC or the Xiph
           tools write, so .oga never pays for a stb_vorbis open. The unguarded
           oggflac_open() below stays as a fallback so that an unrecognized-but-
           still-FLAC mapping degrades to "decodes" rather than to "unsupported". */
        if (ogg_is_flac(bytes, size) && oggflac_open(d)) return d;

        stb_vorbis *v = stb_vorbis_open_memory(d->data, (int)size, &err, NULL);
        if (v) {
            stb_vorbis_info info = stb_vorbis_get_info(v);
            unsigned int len_samples = stb_vorbis_stream_length_in_samples(v);
            if (info.sample_rate > 0 && len_samples > 0) {
                d->kind = DEC_KIND_VORBIS;
                d->vb = v;
                d->vb_channels = info.channels;
                d->vb_rate = info.sample_rate;
                d->duration = (double)len_samples / (double)info.sample_rate;
                return d;
            }
            stb_vorbis_close(v);
        }
        if (oggflac_open(d)) return d;

        /* An Ogg container that is neither vorbis nor FLAC is still an Ogg file,
           never a tracker module: stop here instead of falling through. */
        d->kind = DEC_KIND_NONE;
        free(d->data);
        free(d);
        return NULL;
    }

    if (size >= 26 && memcmp(bytes, "Creative Voice File\x1a", 20) == 0) {
        d->kind = DEC_KIND_VOC;
        if (voc_decode_all(d)) return d;
        d->kind = DEC_KIND_NONE;
        free(d->data);
        free(d);
        return NULL;
    }

    /* WavPack: "wvpk" block header magic */
    if (size >= 8 && memcmp(bytes, "wvpk", 4) == 0) {
        if (wavpack_open(d)) return d;
        /* Recognized WavPack container that will not open (corrupt/truncated):
           fail cleanly rather than re-probing it as a tracker module. */
        free(d->data);
        free(d);
        return NULL;
    }

    /* tracker module via DUMB (any supported format) */
    {
        DUMBFILE *f = dumbfile_open_memory((const char *)d->data, (size_t)d->size);
        if (f) {
            DUH *duh = dumb_read_any(f, 0, 0);
            dumbfile_close(f);
            if (duh) {
                dumb_off_t len = duh_get_length(duh);
                if (len != 0) {
                    d->kind = DEC_KIND_DUMB;
                    d->duh = duh;
                    d->duration = (double)len / 65536.0;
                    dumb_start_renderer(d);
                    if (d->sr) return d;
                    d->kind = DEC_KIND_NONE;
                }
                unload_duh(duh);
            }
        }
    }

    free(d->data);
    free(d);
    return NULL;
}

void dec_close(void *vd) {
    dec_decoder *d = (dec_decoder *)vd;
    if (!d) return;
    switch (d->kind) {
        case DEC_KIND_DUMB:
            if (d->sr) duh_end_sigrenderer(d->sr);
            if (d->duh) unload_duh(d->duh);
            break;
        case DEC_KIND_VORBIS:
            if (d->vb) stb_vorbis_close(d->vb);
            break;
        case DEC_KIND_WAVPACK:
            if (d->wv) WavpackCloseFile(d->wv);
            free(d->wv_src);
            free(d->wv_buf);
            break;
        case DEC_KIND_OGGFLAC:
            oggflac_teardown(d);
            break;
        default:
            break;
    }
    free(d->voc_pcm);
    free(d->data);
    free(d);
}

unsigned int dec_channels(const void *vd) { (void)vd; return 2; }
unsigned int dec_sample_rate(const void *vd) { (void)vd; return OUT_RATE; }

double dec_duration(void *vd) {
    dec_decoder *d = (dec_decoder *)vd;
    return d ? d->duration : 0.0;
}

long dec_render(void *vd, float *out, long frames) {
    dec_decoder *d = (dec_decoder *)vd;
    if (!d || !out || frames <= 0) return 0;
    long produced = 0;
    switch (d->kind) {
        case DEC_KIND_DUMB: {
            if (!d->sr) dumb_start_renderer(d);
            if (!d->sr) return 0;
            short *tmp = (short *)malloc((size_t)frames * 2 * sizeof(short));
            if (!tmp) return 0;
            long n = duh_render(d->sr, 16, 0, 1.0f,
                                DUMB_DELTA, frames, tmp);
            long i;
            for (i = 0; i < n; i++) {
                out[i * 2] = tmp[i * 2] / 32768.0f;
                out[i * 2 + 1] = tmp[i * 2 + 1] / 32768.0f;
            }
            free(tmp);
            produced = n;
            break;
        }
        case DEC_KIND_VORBIS:
            produced = vorbis_fill(d, out, frames);
            break;
        case DEC_KIND_VOC: {
            long avail = d->voc_frames - d->pos_frames;
            produced = avail > frames ? frames : avail;
            if (produced < 0) produced = 0;
            if (produced > 0)
                memcpy(out, d->voc_pcm + d->pos_frames * 2,
                       (size_t)produced * 2 * sizeof(float));
            break;
        }
        case DEC_KIND_WAVPACK:
            produced = wavpack_fill(d, out, frames);
            break;
        case DEC_KIND_OGGFLAC:
            produced = oggflac_fill(d, out, frames);
            break;
        default:
            return 0;
    }
    d->pos_frames += produced;
    return produced;
}

int dec_seek(void *vd, double seconds) {
    dec_decoder *d = (dec_decoder *)vd;
    if (!d) return 0;
    switch (d->kind) {
        case DEC_KIND_DUMB: {
            if (seconds < 0) seconds = 0;
            long target = (long)(seconds * (double)OUT_RATE);
            if (d->sr) { duh_end_sigrenderer(d->sr); d->sr = NULL; }
            dumb_start_renderer(d);
            if (!d->sr) return 0;
            const long CHUNK = 8192;
            short scratch[CHUNK * 2];
            long skipped = 0;
            while (target - skipped > 0) {
                long want = target - skipped;
                long c = want > CHUNK ? CHUNK : want;
                long n = duh_render(d->sr, 16, 0, 0.0f,
                                    DUMB_DELTA, c, scratch);
                if (n <= 0) break;
                skipped += n;
            }
            d->pos_frames = skipped;
            return 1;
        }
        case DEC_KIND_VORBIS: {
            if (!d->vb) return 0;
            if (seconds < 0) seconds = 0;
            unsigned int sample = (unsigned int)(seconds * (double)d->vb_rate);
            if (stb_vorbis_seek(d->vb, sample) == 0) return 0;
            d->res_frac = 0;
            d->res_has_prev = 0;
            d->pos_frames = (long)(seconds * (double)OUT_RATE);
            return 1;
        }
        case DEC_KIND_VOC: {
            long frame = (long)(seconds * (double)OUT_RATE);
            if (frame < 0) frame = 0;
            if (frame > d->voc_frames) frame = d->voc_frames;
            d->pos_frames = frame;
            return 1;
        }
        case DEC_KIND_WAVPACK: {
            if (!d->wv) return 0;
            if (seconds < 0) seconds = 0;
            int64_t target = (int64_t)(seconds * (double)d->wv_rate);
            if (d->duration > 0) {
                int64_t total = WavpackGetNumSamples64(d->wv);
                if (target > total) target = total;
            }
            if (!WavpackSeekSample64(d->wv, target)) return 0;
            d->wv_buf_frames = 0;
            d->wv_buf_used = 0;
            d->res_frac = 0;
            d->res_has_prev = 0;
            d->pos_frames = (long)(seconds * (double)OUT_RATE);
            return 1;
        }
        case DEC_KIND_OGGFLAC: {
            if (!d->of_dec) return 0;
            if (seconds < 0) seconds = 0;
            FLAC__uint64 target = (FLAC__uint64)(seconds * (double)d->of_rate + 0.5);
            /* Clear the staging FIRST: libFLAC writes the frame that contains
               `target`, trimmed to start exactly at it, from inside
               seek_absolute(). Keeping that frame staged is what makes the
               seek sample accurate - discarding it would skip a whole block. */
            d->of_buf_frames = 0;
            d->of_buf_used = 0;
            if (!FLAC__stream_decoder_seek_absolute(d->of_dec, target)) return 0;
            d->of_failed = 0;
            d->res_frac = 0;
            d->res_has_prev = 0;
            d->pos_frames = (long)(seconds * (double)OUT_RATE);
            return 1;
        }
        default:
            return 0;
    }
}

double dec_position(void *vd) {
    dec_decoder *d = (dec_decoder *)vd;
    if (!d) return 0.0;
    return (double)d->pos_frames / (double)OUT_RATE;
}

double dec_probe_duration(const void *data, size_t size) {
    dec_decoder *d = dec_open(data, size);
    if (!d) return 0.0;
    double dur = dec_duration(d);
    dec_close(d);
    return dur;
}
