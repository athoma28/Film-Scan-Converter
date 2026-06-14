#ifndef CLIBRAWSHIM_H
#define CLIBRAWSHIM_H

#include <stddef.h>
#include <stdint.h>

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

#endif
