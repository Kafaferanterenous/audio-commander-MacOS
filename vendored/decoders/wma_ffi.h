/* C shim over the vendored pure-Rust WMA decoder (oxideav-wma, MIT).
 *
 * decoders.c includes this; the symbols are provided by the
 * `oxideav_wma` static library that build.sh / tools/build_tools.sh
 * produce from vendored/wma. The shim also carries the minimal ASF
 * container reader (the crate covers the codec payload only). */
#ifndef WMA_FFI_H
#define WMA_FFI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Must match #[repr(C)] WmaInfoFfi in vendored/wma/src/ffi.rs. */
typedef struct {
    uint32_t sample_rate;
    uint32_t channels;         /* 1 or 2 (decoded width handed back is 2) */
    uint32_t version;          /* 1 or 2 */
    uint64_t total_samples;    /* rough per-packet bound (duration hint) */
} wma_info_t;

/* 1 when `data` is an ASF container holding a WMA v1/v2 audio stream. */
int wma_sniff(const uint8_t *data, size_t size);

/* Borrows `data` until wma_close (same contract as ape_open_file). */
void *wma_open(const uint8_t *data, size_t size);
int wma_info(const void *handle, wma_info_t *out);
int wma_seek(void *handle, uint64_t sample);
/* Interleaved *stereo* int32 at the native rate (mono duplicated). */
int64_t wma_read(void *handle, int32_t *out, int64_t max_frames);
void wma_close(void *handle);

#ifdef __cplusplus
}
#endif

#endif /* WMA_FFI_H */
