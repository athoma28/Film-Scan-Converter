#include "CLibRawShim.h"

#include <libraw/libraw.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static FILE *fsc_log_file = NULL;

static void fsc_log_write(const char *message) {
    time_t now = time(NULL);
    struct tm tm_buf;
    struct tm *tm = localtime_r(&now, &tm_buf);
    char ts[32];
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", tm);
    fprintf(stderr, "%s  %s\n", ts, message);
    fflush(stderr);
    if (fsc_log_file != NULL) {
        fprintf(fsc_log_file, "%s  %s\n", ts, message);
        fflush(fsc_log_file);
    }
}

void fsc_set_log_path(const char *path) {
    if (fsc_log_file != NULL) {
        fclose(fsc_log_file);
    }
    if (path != NULL && path[0] != '\0') {
        fsc_log_file = fopen(path, "a");
    }
}

void fsc_close_log(void) {
    if (fsc_log_file != NULL) {
        fclose(fsc_log_file);
        fsc_log_file = NULL;
    }
}

#define FSC_LOG(fmt, ...) do { \
    char _buf[512]; \
    snprintf(_buf, sizeof(_buf), "[FSC-RAW] " fmt, ##__VA_ARGS__); \
    fsc_log_write(_buf); \
} while (0)

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
    FSC_LOG("decode_raw start: path=%s fullRes=%d", path ? path : "(null)", full_resolution);

    if (path == NULL || output == NULL) {
        FSC_LOG("decode_raw FAIL: null arguments");
        return fail(-1, "Invalid RAW decoder arguments.", error_message, error_message_capacity);
    }
    memset(output, 0, sizeof(*output));

    libraw_data_t *raw = libraw_init(LIBRAW_OPTIONS_NONE);
    if (raw == NULL) {
        FSC_LOG("decode_raw FAIL: libraw_init returned NULL");
        return fail(-1, "LibRaw could not allocate a decoder.", error_message, error_message_capacity);
    }
    FSC_LOG("libraw_init OK");

    int code = check_libraw(libraw_open_file(raw, path), error_message, error_message_capacity);
    if (code != LIBRAW_SUCCESS) {
        FSC_LOG("decode_raw FAIL: libraw_open_file error %d", code);
        libraw_close(raw);
        return code;
    }
    FSC_LOG("libraw_open_file OK: %s", raw->idata.make);

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
    FSC_LOG("params set; unpacking...");

    code = check_libraw(libraw_unpack(raw), error_message, error_message_capacity);
    if (code == LIBRAW_SUCCESS) {
        FSC_LOG("libraw_unpack OK; dcraw processing...");
        code = check_libraw(libraw_dcraw_process(raw), error_message, error_message_capacity);
    }
    if (code != LIBRAW_SUCCESS) {
        FSC_LOG("decode_raw FAIL: unpack/process error %d", code);
        libraw_close(raw);
        return code;
    }
    FSC_LOG("libraw_dcraw_process OK; building memory image...");

    int image_error = LIBRAW_SUCCESS;
    libraw_processed_image_t *processed = libraw_dcraw_make_mem_image(raw, &image_error);
    if (processed == NULL || image_error != LIBRAW_SUCCESS) {
        const char *message = image_error == LIBRAW_SUCCESS
            ? "LibRaw did not return a processed image."
            : libraw_strerror(image_error);
        FSC_LOG("decode_raw FAIL: make_mem_image error %d — %s", image_error, message);
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
    FSC_LOG("make_mem_image OK: %ux%u type=%d bits=%d colors=%d",
            (unsigned)processed->width, (unsigned)processed->height,
            processed->type, processed->bits, processed->colors);

    if (processed->type != LIBRAW_IMAGE_BITMAP
        || processed->bits != 16
        || processed->colors != 3
        || processed->width == 0
        || processed->height == 0) {
        FSC_LOG("decode_raw FAIL: unsupported processed image format");
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
        FSC_LOG("decode_raw FAIL: dimensions exceed buffer size limit");
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
        FSC_LOG("decode_raw FAIL: pixel buffer exceeds allocation limit (%zu pixels)", pixel_count);
        libraw_dcraw_clear_mem(processed);
        libraw_close(raw);
        return fail(
            -1,
            "The decoded RAW buffer exceeds the supported allocation size.",
            error_message,
            error_message_capacity
        );
    }
    size_t alloc_bytes = pixel_count * sizeof(uint16_t);
    FSC_LOG("allocating %zu bytes for %zu pixels", alloc_bytes, pixel_count);
    uint16_t *pixels = malloc(alloc_bytes);
    if (pixels == NULL) {
        FSC_LOG("decode_raw FAIL: malloc returned NULL (%zu bytes)", alloc_bytes);
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

    FSC_LOG("decode_raw SUCCESS: %ux%u %uch %zu pixels cdesc=%.4s",
            output->width, output->height, output->channels,
            output->pixel_count, raw->idata.cdesc);

    libraw_dcraw_clear_mem(processed);
    libraw_close(raw);
    return LIBRAW_SUCCESS;
}

void fsc_free_raw_image(fsc_raw_image *image) {
    if (image == NULL) {
        return;
    }
    FSC_LOG("free_raw_image: %p (%zu pixels)", (void *)image->pixels, image->pixel_count);
    free(image->pixels);
    memset(image, 0, sizeof(*image));
}

const char *fsc_libraw_version(void) {
    return libraw_version();
}
