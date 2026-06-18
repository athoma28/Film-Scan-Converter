#ifndef CLIBRAWSHIM_H
#define CLIBRAWSHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t channels;
    size_t pixel_count;
    uint16_t *pixels;
    char color_description[5];
} fsc_raw_image;

int fsc_decode_raw(
    const char *path,
    int full_resolution,
    fsc_raw_image *output,
    char *error_message,
    size_t error_message_capacity
);

void fsc_free_raw_image(fsc_raw_image *image);
const char *fsc_libraw_version(void);
void fsc_set_log_path(const char *path);
void fsc_close_log(void);

typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t channels;
    size_t pixel_count;
    char color_description[5];
    float iso_speed;
    uint32_t processing_flags;
    const uint16_t *bgr_pixels;
    void *_internal;
} fsc_raw_direct;

enum {
    FSC_RAW_PROCESSING_RCD = 1u << 0,
    FSC_RAW_PROCESSING_REC2020 = 1u << 1,
    FSC_RAW_PROCESSING_ISO_DENOISE = 1u << 2,
    FSC_RAW_PROCESSING_ISO_SHARPEN = 1u << 3
};

typedef enum {
    FSC_RAW_DECODE_PROFILE_RAWPY_COMPATIBILITY = 0,
    FSC_RAW_DECODE_PROFILE_RAWTHERAPEE_CAMERA_SCAN = 1
} fsc_raw_decode_profile;

int fsc_decode_raw_direct(
    const char *path,
    int full_resolution,
    fsc_raw_direct *output,
    char *error_message,
    size_t error_message_capacity
);

int fsc_decode_raw_direct_with_profile(
    const char *path,
    int full_resolution,
    fsc_raw_decode_profile profile,
    fsc_raw_direct *output,
    char *error_message,
    size_t error_message_capacity
);

void fsc_free_raw_direct(fsc_raw_direct *output);

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
