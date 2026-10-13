/* C shim over the vendored pure-Rust Monkey's Audio decoder (ape-rs, MIT).
 *
 * decoders.c includes this; the symbols are provided by the `ape_rs` static
 * library that build.sh / build_tools.sh produce from vendored/ape-rs. */
#ifndef APE_FFI_H
#define APE_FFI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Must match #[repr(C)] ApeInfoFfi in vendored/ape-rs/src/ffi.rs. */
typedef struct {
    uint32_t sample_rate;
    uint32_t channels;
    uint32_t bits_per_sample;
    uint64_t total_frames;      /* per-channel frames, not interleaved */
    uint32_t blocks_per_frame;
    uint32_t compression_level;
    uint32_t format_version;
} ape_info_t;

void *ape_open_file(const uint8_t *data, size_t size);
int ape_info(const void *handle, ape_info_t *out);
int ape_seek(void *handle, uint64_t sample);
int64_t ape_read(void *handle, int32_t *out, size_t max_frames);
void ape_close(void *handle);

#ifdef __cplusplus
}
#endif

#endif /* APE_FFI_H */
