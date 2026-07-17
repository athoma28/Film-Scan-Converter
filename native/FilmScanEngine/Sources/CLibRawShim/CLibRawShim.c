#include "CLibRawShim.h"

#include <libraw/libraw.h>
#include <malloc/malloc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

int fsc_decode_rawtherapee_direct(
    const char *path,
    int full_resolution,
    fsc_raw_direct *output,
    char *error_message,
    size_t error_message_capacity
);

#ifdef DEBUG
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

#define FSC_LOG(fmt, ...) do { \
    char _buf[512]; \
    snprintf(_buf, sizeof(_buf), "[FSC-RAW] " fmt, ##__VA_ARGS__); \
    fsc_log_write(_buf); \
} while (0)
#else
#define FSC_LOG(fmt, ...) do { } while (0)
void fsc_set_log_path(const char *path) { (void)path; }
#endif

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

static void set_rawpy_compatibility_params(libraw_data_t *raw, int full_resolution) {
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
}

static void set_rawtherapee_camera_scan_params(libraw_data_t *raw, int full_resolution) {
    raw->params.output_bps = 16;
    raw->params.use_camera_wb = 1;
    for (int index = 0; index < 4; index++) {
        raw->params.user_mul[index] = 1.0f;
    }
    raw->params.user_qual = 2;
    raw->params.fbdd_noiserd = 0;
    // Keep the bridge output display-encoded so standard-image and RAW inputs
    // share one inversion contract. The film-negative stage linearizes before
    // applying RawTherapee's power law.
    raw->params.output_color = 1;
    raw->params.gamm[0] = 1.0 / 2.4;
    raw->params.gamm[1] = 12.92;
    raw->params.auto_bright_thr = 0.0f;
    raw->params.adjust_maximum_thr = 0.75f;
    raw->params.bright = 1.0f;
    raw->params.highlight = 3;
    raw->params.no_auto_bright = 1;
    raw->params.no_auto_scale = 0;
    raw->params.med_passes = 0;
    raw->params.threshold = 0.0f;
    raw->params.exp_correc = 0;
    raw->params.exp_shift = 1.0f;
    raw->params.exp_preser = 1.0f;
    raw->params.half_size = full_resolution ? 0 : 1;
}

static int set_decode_params(
    libraw_data_t *raw,
    int full_resolution,
    fsc_raw_decode_profile profile,
    char *error_message,
    size_t error_message_capacity
) {
    switch (profile) {
        case FSC_RAW_DECODE_PROFILE_RAWPY_COMPATIBILITY:
            set_rawpy_compatibility_params(raw, full_resolution);
            return LIBRAW_SUCCESS;
        case FSC_RAW_DECODE_PROFILE_RAWTHERAPEE_CAMERA_SCAN:
            set_rawtherapee_camera_scan_params(raw, full_resolution);
            return LIBRAW_SUCCESS;
        default:
            return fail(-1, "Unknown RAW decode profile.", error_message, error_message_capacity);
    }
}

typedef struct {
    libraw_processed_image_t *processed;
} fsc_direct_cleanup;

int fsc_decode_raw_direct_with_profile(
    const char *path,
    int full_resolution,
    fsc_raw_decode_profile profile,
    fsc_raw_direct *output,
    char *error_message,
    size_t error_message_capacity
) {
    FSC_LOG("decode_raw_direct start: path=%s fullRes=%d profile=%d", path ? path : "(null)", full_resolution, profile);

    if (path == NULL || output == NULL) {
        FSC_LOG("decode_raw_direct FAIL: null arguments");
        return fail(-1, "Invalid RAW decoder arguments.", error_message, error_message_capacity);
    }
    memset(output, 0, sizeof(*output));

    if (profile == FSC_RAW_DECODE_PROFILE_RAWTHERAPEE_CAMERA_SCAN) {
        return fsc_decode_rawtherapee_direct(
            path, full_resolution, output, error_message, error_message_capacity
        );
    }

    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        FSC_LOG("decode_raw_direct FAIL: cannot open file");
        return fail(-1, "Cannot open RAW file.", error_message, error_message_capacity);
    }
    struct stat st;
    if (fstat(fd, &st) < 0 || st.st_size <= 0) {
        FSC_LOG("decode_raw_direct FAIL: cannot stat file or zero size");
        close(fd);
        return fail(-1, "Cannot read RAW file size.", error_message, error_message_capacity);
    }
    void *mapped = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (mapped == MAP_FAILED) {
        FSC_LOG("decode_raw_direct FAIL: mmap failed");
        return fail(-1, "Cannot memory-map RAW file.", error_message, error_message_capacity);
    }
    FSC_LOG("mmap OK: %lld bytes", (long long)st.st_size);

    libraw_data_t *raw = libraw_init(LIBRAW_OPTIONS_NONE);
    if (raw == NULL) {
        FSC_LOG("decode_raw_direct FAIL: libraw_init returned NULL");
        munmap(mapped, (size_t)st.st_size);
        return fail(-1, "LibRaw could not allocate a decoder.", error_message, error_message_capacity);
    }
    FSC_LOG("libraw_init OK");

    int code = check_libraw(libraw_open_buffer(raw, mapped, (size_t)st.st_size), error_message, error_message_capacity);
    if (code != LIBRAW_SUCCESS) {
        FSC_LOG("decode_raw_direct FAIL: libraw_open_buffer error %d", code);
        libraw_close(raw);
        munmap(mapped, (size_t)st.st_size);
        return code;
    }
    FSC_LOG("libraw_open_buffer OK: %s", raw->idata.make);

    code = set_decode_params(raw, full_resolution, profile, error_message, error_message_capacity);
    if (code != LIBRAW_SUCCESS) {
        libraw_close(raw);
        munmap(mapped, (size_t)st.st_size);
        return code;
    }
    FSC_LOG("params set; unpacking...");

    code = check_libraw(libraw_unpack(raw), error_message, error_message_capacity);
    munmap(mapped, (size_t)st.st_size);
    mapped = NULL;
    if (code == LIBRAW_SUCCESS) {
        FSC_LOG("libraw_unpack OK; dcraw processing...");
        code = check_libraw(libraw_dcraw_process(raw), error_message, error_message_capacity);
    }
    if (code != LIBRAW_SUCCESS) {
        FSC_LOG("decode_raw_direct FAIL: unpack/process error %d", code);
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
        FSC_LOG("decode_raw_direct FAIL: make_mem_image error %d — %s", image_error, message);
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
        FSC_LOG("decode_raw_direct FAIL: unsupported processed image format");
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
    size_t pixel_count = width * height * colors;

    output->width = (uint32_t)width;
    output->height = (uint32_t)height;
    output->channels = (uint32_t)colors;
    output->pixel_count = pixel_count;
    output->iso_speed = raw->other.iso_speed;
    output->processing_flags = 0;
    output->bgr_pixels = (const uint16_t *)processed->data;
    snprintf(output->color_description, sizeof(output->color_description), "%.4s", raw->idata.cdesc);

    libraw_close(raw);

    fsc_direct_cleanup *cleanup = malloc(sizeof(fsc_direct_cleanup));
    cleanup->processed = processed;
    output->_internal = cleanup;

    FSC_LOG("decode_raw_direct SUCCESS: %ux%u %uch %zu pixels cdesc=%.4s",
            output->width, output->height, output->channels,
            output->pixel_count, output->color_description);

    return LIBRAW_SUCCESS;
}

void fsc_free_raw_direct(fsc_raw_direct *output) {
    if (output == NULL) {
        return;
    }
    FSC_LOG("free_raw_direct: %p (%zu pixels)", (void *)output->bgr_pixels, output->pixel_count);
    fsc_direct_cleanup *cleanup = (fsc_direct_cleanup *)output->_internal;
    if (cleanup != NULL) {
        libraw_dcraw_clear_mem(cleanup->processed);
        free(cleanup);
    }
    memset(output, 0, sizeof(*output));
}

int fsc_raw_full_dimensions(
    const char *path,
    fsc_raw_dimensions *output,
    char *error_message,
    size_t error_message_capacity
) {
    if (path == NULL || output == NULL) {
        return fail(-1, "Invalid RAW dimension arguments.", error_message, error_message_capacity);
    }
    memset(output, 0, sizeof(*output));

    libraw_data_t *raw = libraw_init(LIBRAW_OPTIONS_NONE);
    if (raw == NULL) {
        return fail(-1, "LibRaw could not allocate a metadata reader.", error_message, error_message_capacity);
    }
    int code = check_libraw(
        libraw_open_file(raw, path), error_message, error_message_capacity
    );
    if (code == LIBRAW_SUCCESS) {
        raw->params.half_size = 0;
        code = check_libraw(
            libraw_adjust_sizes_info_only(raw), error_message, error_message_capacity
        );
    }
    if (code == LIBRAW_SUCCESS) {
        uint32_t width = raw->sizes.iwidth;
        uint32_t height = raw->sizes.iheight;
        if (raw->sizes.flip == 5 || raw->sizes.flip == 6) {
            uint32_t temporary = width;
            width = height;
            height = temporary;
        }
        if (width == 0 || height == 0) {
            code = fail(-1, "LibRaw returned empty RAW dimensions.", error_message, error_message_capacity);
        } else {
            output->width = width;
            output->height = height;
        }
    }
    libraw_close(raw);
    return code;
}

int fsc_default_heap_statistics(fsc_heap_statistics *output) {
    if (output == NULL) {
        return -1;
    }

    malloc_zone_t *zone = malloc_default_zone();
    if (zone == NULL || zone->introspect == NULL || zone->introspect->statistics == NULL) {
        memset(output, 0, sizeof(*output));
        return -1;
    }

    malloc_statistics_t statistics = {0};
    zone->introspect->statistics(zone, &statistics);
    output->blocks_in_use = statistics.blocks_in_use;
    output->size_in_use = statistics.size_in_use;
    // Some current macOS allocator zones report a zero high-water mark even
    // while live allocations are present. Preserve the useful invariant for
    // diagnostics without pretending to know an unavailable historical peak.
    output->max_size_in_use = statistics.max_size_in_use > statistics.size_in_use
        ? statistics.max_size_in_use
        : statistics.size_in_use;
    output->size_allocated = statistics.size_allocated;
    return 0;
}

typedef struct {
    libraw_data_t *raw;
    void *mapped_file;
    size_t mapped_size;
    uint8_t *thumbnail_copy;
} fsc_thumbnail_cleanup;

int fsc_extract_thumbnail(
    const char *path,
    fsc_raw_thumbnail *output,
    char *error_message,
    size_t error_message_capacity
) {
    FSC_LOG("extract_thumbnail start: path=%s", path ? path : "(null)");

    if (path == NULL || output == NULL) {
        FSC_LOG("extract_thumbnail FAIL: null arguments");
        return fail(-1, "Invalid thumbnail arguments.", error_message, error_message_capacity);
    }
    memset(output, 0, sizeof(*output));

    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        FSC_LOG("extract_thumbnail FAIL: cannot open file");
        return fail(-1, "Cannot open RAW file.", error_message, error_message_capacity);
    }
    struct stat st;
    if (fstat(fd, &st) < 0 || st.st_size <= 0) {
        FSC_LOG("extract_thumbnail FAIL: cannot stat file");
        close(fd);
        return fail(-1, "Cannot read RAW file size.", error_message, error_message_capacity);
    }
    void *mapped = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (mapped == MAP_FAILED) {
        FSC_LOG("extract_thumbnail FAIL: mmap failed");
        return fail(-1, "Cannot memory-map RAW file.", error_message, error_message_capacity);
    }

    libraw_data_t *raw = libraw_init(LIBRAW_OPTIONS_NONE);
    if (raw == NULL) {
        FSC_LOG("extract_thumbnail FAIL: libraw_init returned NULL");
        munmap(mapped, (size_t)st.st_size);
        return fail(-1, "LibRaw could not allocate a decoder.", error_message, error_message_capacity);
    }

    int code = check_libraw(libraw_open_buffer(raw, mapped, (size_t)st.st_size), error_message, error_message_capacity);
    if (code != LIBRAW_SUCCESS) {
        FSC_LOG("extract_thumbnail FAIL: libraw_open_buffer error %d", code);
        libraw_close(raw);
        munmap(mapped, (size_t)st.st_size);
        return code;
    }

    code = check_libraw(libraw_unpack_thumb(raw), error_message, error_message_capacity);
    if (code != LIBRAW_SUCCESS) {
        FSC_LOG("extract_thumbnail FAIL: libraw_unpack_thumb error %d — no embedded preview", code);
        libraw_close(raw);
        munmap(mapped, (size_t)st.st_size);
        return code;
    }

    if (raw->thumbnail.tformat != LIBRAW_THUMBNAIL_JPEG) {
        FSC_LOG("extract_thumbnail FAIL: unsupported thumbnail format %d", raw->thumbnail.tformat);
        libraw_close(raw);
        munmap(mapped, (size_t)st.st_size);
        return fail(-2, "RAW file has no embedded JPEG preview.", error_message, error_message_capacity);
    }

    size_t jpeg_size = raw->thumbnail.tlength;
    const uint8_t *jpeg_data = (const uint8_t *)raw->thumbnail.thumb;
    if (jpeg_data == NULL || jpeg_size == 0) {
        FSC_LOG("extract_thumbnail FAIL: empty JPEG data");
        libraw_close(raw);
        munmap(mapped, (size_t)st.st_size);
        return fail(-1, "Embedded JPEG preview is empty.", error_message, error_message_capacity);
    }

    uint8_t *copy = malloc(jpeg_size);
    if (copy == NULL) {
        FSC_LOG("extract_thumbnail FAIL: malloc for JPEG copy");
        libraw_close(raw);
        munmap(mapped, (size_t)st.st_size);
        return fail(-1, "Cannot allocate JPEG preview buffer.", error_message, error_message_capacity);
    }
    memcpy(copy, jpeg_data, jpeg_size);

    output->width = (uint32_t)raw->thumbnail.twidth;
    output->height = (uint32_t)raw->thumbnail.theight;
    output->data = copy;
    output->data_size = jpeg_size;

    fsc_thumbnail_cleanup *cleanup = malloc(sizeof(fsc_thumbnail_cleanup));
    cleanup->raw = raw;
    cleanup->mapped_file = mapped;
    cleanup->mapped_size = (size_t)st.st_size;
    cleanup->thumbnail_copy = copy;
    output->_internal = cleanup;

    FSC_LOG("extract_thumbnail SUCCESS: %ux%u JPEG %zu bytes",
            output->width, output->height, output->data_size);

    return LIBRAW_SUCCESS;
}

void fsc_free_thumbnail(fsc_raw_thumbnail *output) {
    if (output == NULL) {
        return;
    }
    FSC_LOG("free_thumbnail: %p (%zu bytes)", (void *)output->data, output->data_size);
    fsc_thumbnail_cleanup *cleanup = (fsc_thumbnail_cleanup *)output->_internal;
    if (cleanup != NULL) {
        free(cleanup->thumbnail_copy);
        libraw_close(cleanup->raw);
        munmap(cleanup->mapped_file, cleanup->mapped_size);
        free(cleanup);
    }
    memset(output, 0, sizeof(*output));
}

const char *fsc_libraw_version(void) {
    return libraw_version();
}
