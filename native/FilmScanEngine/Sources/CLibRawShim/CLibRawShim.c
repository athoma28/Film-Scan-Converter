#include "CLibRawShim.h"

#include <libraw/libraw.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fail(
    int code,
    const char *message,
    char *error_message,
    size_t error_message_capacity
) {
    if (error_message != NULL && error_message_capacity > 0) {
        snprintf(error_message, error_message_capacity, "%s", message);
    }
    return code;
}

static int check_libraw(
    int code,
    char *error_message,
    size_t error_message_capacity
) {
    if (code == LIBRAW_SUCCESS) {
        return LIBRAW_SUCCESS;
    }
    return fail(code, libraw_strerror(code), error_message, error_message_capacity);
}

int fsc_decode_raw(
    const char *path,
    int full_resolution,
    fsc_raw_image *output,
    char *error_message,
    size_t error_message_capacity
) {
    if (path == NULL || output == NULL) {
        return fail(-1, "Invalid RAW decoder arguments.", error_message, error_message_capacity);
    }
    memset(output, 0, sizeof(*output));

    libraw_data_t *raw = libraw_init(LIBRAW_OPTIONS_NONE);
    if (raw == NULL) {
        return fail(-1, "LibRaw could not allocate a decoder.", error_message, error_message_capacity);
    }

    int code = check_libraw(libraw_open_file(raw, path), error_message, error_message_capacity);
    if (code != LIBRAW_SUCCESS) {
        libraw_close(raw);
        return code;
    }

    raw->params.output_bps = 16;
    raw->params.use_camera_wb = 1;
    for (int index = 0; index < 4; index++) {
        raw->params.user_mul[index] = 1.0f;
    }
    raw->params.user_qual = 2;
    raw->params.fbdd_noiserd = 0;
    raw->params.output_color = 7;
    raw->params.gamm[0] = 1.0 / 2.222;
    raw->params.gamm[1] = 4.5;
    raw->params.auto_bright_thr = 0.0f;
    raw->params.adjust_maximum_thr = 0.75f;
    raw->params.bright = 1.0f;
    raw->params.highlight = 0;
    raw->params.no_auto_bright = 0;
    raw->params.no_auto_scale = 0;
    raw->params.med_passes = 0;
    raw->params.threshold = 0.0f;
    raw->params.exp_correc = 1;
    raw->params.exp_shift = 8.0f;
    raw->params.exp_preser = 1.0f;
    raw->params.half_size = full_resolution ? 0 : 1;

    code = check_libraw(libraw_unpack(raw), error_message, error_message_capacity);
    if (code == LIBRAW_SUCCESS) {
        code = check_libraw(libraw_dcraw_process(raw), error_message, error_message_capacity);
    }
    if (code != LIBRAW_SUCCESS) {
        libraw_close(raw);
        return code;
    }

    int image_error = LIBRAW_SUCCESS;
    libraw_processed_image_t *processed = libraw_dcraw_make_mem_image(raw, &image_error);
    if (processed == NULL || image_error != LIBRAW_SUCCESS) {
        const char *message = image_error == LIBRAW_SUCCESS
            ? "LibRaw did not return a processed image."
            : libraw_strerror(image_error);
        code = fail(
            image_error == LIBRAW_SUCCESS ? -1 : image_error,
            message,
            error_message,
            error_message_capacity
        );
        if (processed != NULL) {
            libraw_dcraw_clear_mem(processed);
        }
        libraw_close(raw);
        return code;
    }
    if (processed->type != LIBRAW_IMAGE_BITMAP
        || processed->bits != 16
        || processed->colors != 3
        || processed->width == 0
        || processed->height == 0) {
        libraw_dcraw_clear_mem(processed);
        libraw_close(raw);
        return fail(
            -1,
            "LibRaw returned an unsupported processed image format.",
            error_message,
            error_message_capacity
        );
    }

    size_t width = processed->width;
    size_t height = processed->height;
    size_t colors = processed->colors;
    if (height > SIZE_MAX / width || colors > SIZE_MAX / (width * height)) {
        libraw_dcraw_clear_mem(processed);
        libraw_close(raw);
        return fail(
            -1,
            "The decoded RAW dimensions exceed the supported buffer size.",
            error_message,
            error_message_capacity
        );
    }
    size_t pixel_count = width * height * colors;
    if (pixel_count > SIZE_MAX / sizeof(uint16_t)) {
        libraw_dcraw_clear_mem(processed);
        libraw_close(raw);
        return fail(
            -1,
            "The decoded RAW buffer exceeds the supported allocation size.",
            error_message,
            error_message_capacity
        );
    }
    uint16_t *pixels = malloc(pixel_count * sizeof(uint16_t));
    if (pixels == NULL) {
        libraw_dcraw_clear_mem(processed);
        libraw_close(raw);
        return fail(-1, "Unable to allocate the decoded RAW buffer.", error_message, error_message_capacity);
    }

    const uint16_t *rgb = (const uint16_t *)processed->data;
    for (size_t index = 0; index < pixel_count; index += 3) {
        pixels[index] = rgb[index + 2];
        pixels[index + 1] = rgb[index + 1];
        pixels[index + 2] = rgb[index];
    }

    output->width = processed->width;
    output->height = processed->height;
    output->channels = processed->colors;
    output->pixel_count = pixel_count;
    output->pixels = pixels;
    snprintf(output->color_description, sizeof(output->color_description), "%.4s", raw->idata.cdesc);

    libraw_dcraw_clear_mem(processed);
    libraw_close(raw);
    return LIBRAW_SUCCESS;
}

void fsc_free_raw_image(fsc_raw_image *image) {
    if (image == NULL) {
        return;
    }
    free(image->pixels);
    memset(image, 0, sizeof(*image));
}

const char *fsc_libraw_version(void) {
    return libraw_version();
}
