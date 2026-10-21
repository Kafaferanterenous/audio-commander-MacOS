/* C shim over the vendored pure-Rust DTS decoder (oxideav-dts, MIT).
 *
 * decoders.c includes this; the symbols are provided by the
 * `oxideav_dts` static library that build.sh / tools/build_tools.sh
 * produce from vendored/dts. */
#ifndef DTS_FFI_H
#define DTS_FFI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Must match #[repr(C)] DtsInfoFfi in vendored/dts/src/ffi.rs. */
typedef struct {
    uint32_t sample_rate;
    uint32_t channels;         /* primary planes (transmission order) */
    uint32_t has_lfe;          /* 1 when an LFE plane trails the primaries */
    uint32_t amode;            /* raw AMODE channel-configuration code */
    uint64_t total_samples;    /* per-plane frames dts_read will yield */
} dts_info_t;

/* 1 when a parseable DTS Core frame header starts at offset 0. */
int dts_sniff(const uint8_t *data, size_t size);

/* Borrows `data` until dts_close (same contract as ape_open_file). */
void *dts_open(const uint8_t *data, size_t size);
int dts_info(const void *handle, dts_info_t *out);
int dts_seek(void *handle, uint64_t sample);
int64_t dts_read(void *handle, int32_t *out, int64_t max_frames);
void dts_close(void *handle);

#ifdef __cplusplus
}
#endif

#endif /* DTS_FFI_H */
