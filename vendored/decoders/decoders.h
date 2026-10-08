#ifndef AC_DECODERS_H
#define AC_DECODERS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 Unified embedded decoder for AudioCommander.
 Supported: tracker modules via DUMB (MOD/S3M/XM/IT/669/AMF/AMS/DSM/FAR/
 MTM/OKT/PSM/PTM/STM/ULT), OGG Vorbis via stb_vorbis, Creative Voice (.voc),
 WavPack (.wv) via libwavpack (BSD 2-Clause), DSF/DFF (DSD64→PCM44.1k, DSD128→PCM44.1k).
 All output: interleaved stereo float32 at 44100 Hz.
 Handles are opaque (void*) so the API imports cleanly into Swift.
*/

void *dec_open(const void *data, size_t size);
void dec_close(void *d);

unsigned int dec_channels(const void *d); /* always 2 */
unsigned int dec_sample_rate(const void *d); /* always 44100 */

double dec_duration(void *d); /* seconds, <=0 if unknown */
double dec_position(void *d); /* seconds based on frames rendered */

/* Renders up to `frames` frames into `out` (interleaved L R L R...).
   Returns number of frames rendered; 0 means end of stream. */
long dec_render(void *d, float *out, long frames);

/* Repositions playback. Returns 0 on failure, 1 on success. */
int dec_seek(void *d, double seconds);

/* One-shot probe: open, measure duration, close. Thread-safe. */
double dec_probe_duration(const void *data, size_t size);

#ifdef __cplusplus
}
#endif

#endif /* AC_DECODERS_H */
