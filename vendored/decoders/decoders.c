#include "decoders.h"

#include <stdlib.h>
#include <string.h>

#include "dumb.h"
#include "stb_vorbis.c" /* declarations only (no STB_VORBIS_IMPLEMENTATION here) */

#define OUT_RATE 44100
/* DUMB delta_time = 65536 (units/sec) / output rate: fixed-point seconds per
 * output sample. The reciprocal here used to slow tracker playback ~2.2x. */
#define DUMB_DELTA (65536.0f / (float)OUT_RATE)

typedef struct dec_decoder dec_decoder;

enum dec_kind {
    DEC_KIND_NONE = 0,
    DEC_KIND_DUMB,
    DEC_KIND_VORBIS,
    DEC_KIND_VOC
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
        /* ogg container without vorbis audio -> fall through and fail below */
    }

    if (size >= 26 && memcmp(bytes, "Creative Voice File\x1a", 20) == 0) {
        d->kind = DEC_KIND_VOC;
        if (voc_decode_all(d)) return d;
        d->kind = DEC_KIND_NONE;
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
