#ifndef CLIBRAWSHIM_H
#define CLIBRAWSHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

const char *fsc_libraw_version(void);
void fsc_set_log_path(const char *path);

typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t channels;
    size_t pixel_count;
    char color_description[5];
    float iso_speed;
    uint32_t processing_flags;
    double open_seconds;
    double unpack_seconds;
    double demosaic_seconds;
    double libraw_postprocess_seconds;
    double processed_image_seconds;
    double iso_policy_seconds;
    const uint16_t *bgr_pixels;
    void *_internal;
} fsc_raw_direct;

enum {
    FSC_RAW_PROCESSING_RCD = 1u << 0,
    FSC_RAW_PROCESSING_REC2020 = 1u << 1,
    FSC_RAW_PROCESSING_ISO_DENOISE = 1u << 2,
    FSC_RAW_PROCESSING_ISO_SHARPEN = 1u << 3,
    FSC_RAW_PROCESSING_XTRANS_THREE_PASS = 1u << 4
};

typedef enum {
    FSC_RAW_DECODE_PROFILE_RAWPY_COMPATIBILITY = 0,
    FSC_RAW_DECODE_PROFILE_RAWTHERAPEE_CAMERA_SCAN = 1
} fsc_raw_decode_profile;

int fsc_decode_raw_direct_with_profile(
    const char *path,
    int full_resolution,
    fsc_raw_decode_profile profile,
    fsc_raw_direct *output,
    char *error_message,
    size_t error_message_capacity
);

#define FSC_RAW_STAGE_HASH_HEX_SIZE 65

// Opt-in camera-scan decode diagnostics: SHA-256 digests captured at stage
// boundaries so a repeated-decode determinism run can isolate the first
// divergent stage without storing full intermediates. A successful diagnostic
// decode must populate every digest; an empty digest is incomplete evidence
// and must not be treated as agreement.
typedef struct {
    // Unpacked-mosaic metadata folded into the mosaic digest.
    uint32_t mosaic_raw_width;
    uint32_t mosaic_raw_height;
    uint32_t mosaic_filters;
    uint32_t mosaic_cfa_bytes;
    // After unpack(): mosaic dimensions/CFA metadata plus the raw mosaic.
    char unpacked_mosaic_sha256[FSC_RAW_STAGE_HASH_HEX_SIZE];
    // Inside the demosaic callback, immediately after interpolation returns,
    // before the remaining dcraw_process stages.
    char demosaiced_sha256[FSC_RAW_STAGE_HASH_HEX_SIZE];
    // The image returned by dcraw_make_mem_image (after the preview
    // downsample when that path runs), before the ISO-adaptive filter.
    char processed_image_sha256[FSC_RAW_STAGE_HASH_HEX_SIZE];
    // The same buffer after the ISO-adaptive filter.
    char post_iso_sha256[FSC_RAW_STAGE_HASH_HEX_SIZE];
} fsc_raw_stage_hashes;

// Same contract as fsc_decode_raw_direct_with_profile, plus opt-in
// stage-boundary digest capture. Passing NULL for stage_hashes keeps the
// production decode free of hashing work. Digests are collected on the
// camera-scan path only; other profiles zero the structure and leave every
// digest empty. Digests compare runs of the same build on the same machine;
// they hash raw buffer bytes and are not a cross-platform identity contract.
int fsc_decode_raw_direct_with_profile_diagnostics(
    const char *path,
    int full_resolution,
    fsc_raw_decode_profile profile,
    fsc_raw_direct *output,
    fsc_raw_stage_hashes *stage_hashes,
    char *error_message,
    size_t error_message_capacity
);

void fsc_free_raw_direct(fsc_raw_direct *output);

typedef struct {
    uint32_t width;
    uint32_t height;
} fsc_raw_dimensions;

// Reads the full-resolution processed-image dimensions without unpacking or
// demosaicing the RAW. The result follows LibRaw's metadata orientation.
int fsc_raw_full_dimensions(
    const char *path,
    fsc_raw_dimensions *output,
    char *error_message,
    size_t error_message_capacity
);

typedef struct {
    size_t blocks_in_use;
    size_t size_in_use;
    size_t max_size_in_use;
    size_t size_allocated;
} fsc_heap_statistics;

// Captures the default allocator zone's live and reserved byte counts. This is
// diagnostic-only: use it to distinguish live allocations from allocator
// retention when measuring a sequential full-resolution export run.
int fsc_default_heap_statistics(fsc_heap_statistics *output);

typedef struct {
    uint32_t width;
    uint32_t height;
    const void *data;
    size_t data_size;
    void *_internal;
} fsc_raw_thumbnail;

int fsc_extract_thumbnail(
    const char *path,
    fsc_raw_thumbnail *output,
    char *error_message,
    size_t error_message_capacity
);

void fsc_free_thumbnail(fsc_raw_thumbnail *output);

#ifdef __cplusplus
}
#endif

#endif
