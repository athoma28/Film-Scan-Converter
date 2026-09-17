#include "../FilmScanEngine/Sources/CLibRawShim/RawDecodeCompatibility.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

static void make_x_t5(libraw_data_t *raw) {
    memset(raw, 0, sizeof(*raw));
    raw->idata.maker_index = LIBRAW_CAMERAMAKER_Fujifilm;
    strcpy(raw->idata.model, "X-T5");
    raw->idata.filters = 9;
    raw->makernotes.fuji.RAFDataGeneration = 4;
    raw->makernotes.fuji.RAFData_ImageSizeTable[0] = 7752;
    raw->makernotes.fuji.RAFData_ImageSizeTable[1] = 5184;
    raw->sizes.raw_width = 7872;
    raw->sizes.raw_height = 5196;
    raw->sizes.width = raw->sizes.iwidth = 7752;
    raw->sizes.height = raw->sizes.iheight = 5178;
    raw->sizes.top_margin = 6;
    // Sentinels for fields that must survive compatibility handling.
    raw->sizes.flip = 6;
    raw->sizes.raw_pitch = 15744;
    raw->color.black = 1024;
    raw->idata.xtrans[0][0] = 1;
    raw->sizes.raw_inset_crops[0].cwidth = 7728;
    raw->rawdata.sizes = raw->sizes;
}

static void expect_unchanged(libraw_data_t *raw, libraw_data_t *expected) {
    memcpy(expected, raw, sizeof(*raw));
    fsc_restore_legacy_raw_geometry(raw);
    fsc_restore_legacy_raw_color(raw);
    assert(memcmp(raw, expected, sizeof(*raw)) == 0);
}

static void make_x_t5_color(libraw_data_t *raw) {
    const float xyz[4][3] = {
        {1.1809f, -0.5358f, -0.1141f},
        {-0.4248f, 1.2164f, 0.2343f},
        {-0.0514f, 0.1097f, 0.5848f},
        {0.f, 0.f, 0.f}
    };
    make_x_t5(raw);
    fsc_restore_legacy_raw_geometry(raw);
    memcpy(raw->color.cam_xyz, xyz, sizeof(xyz));
    raw->color.pre_mul[0] = 2.162749f;
    raw->color.rgb_cam[0][0] = 1.256047487f;
    raw->color.cam_mul[0] = 631.f;
    raw->color.cam_mul[1] = 302.f;
    raw->color.cam_mul[2] = 567.f;
    raw->rawdata.color = raw->color;
}

int main(void) {
    libraw_data_t *raw = (libraw_data_t *)calloc(1, sizeof(*raw));
    libraw_data_t *expected = (libraw_data_t *)calloc(1, sizeof(*expected));
    assert(raw && expected);

    make_x_t5(raw);
    memcpy(expected, raw, sizeof(*raw));
    expected->sizes.left_margin = 60;
    expected->sizes.height = expected->sizes.iheight = 5184;
    expected->rawdata.sizes = expected->sizes;
    fsc_restore_legacy_raw_geometry(raw);
    assert(memcmp(raw, expected, sizeof(*raw)) == 0);
    // Already restored / LibRaw 0.21.4 geometry stays unchanged.
    expect_unchanged(raw, expected);

    // Camera crop modes and converted DNGs must retain their own coordinates.
    const unsigned short crop_modes[] = {1, 2, 4};
    for (unsigned i = 0; i < sizeof(crop_modes) / sizeof(crop_modes[0]); ++i) {
        make_x_t5(raw);
        raw->makernotes.fuji.CropMode = crop_modes[i];
        expect_unchanged(raw, expected);
    }
    make_x_t5(raw);
    raw->idata.dng_version = 0x01040000;
    expect_unchanged(raw, expected);

    // An adjacent camera model is not evidence of the same source contract.
    make_x_t5(raw);
    strcpy(raw->idata.model, "X-H2");
    expect_unchanged(raw, expected);
    make_x_t5(raw);
    raw->idata.maker_index = LIBRAW_CAMERAMAKER_Sony;
    expect_unchanged(raw, expected);
    make_x_t5(raw);
    raw->idata.filters = 0x94949494;
    expect_unchanged(raw, expected);

    // Incomplete metadata and future sensor/layout changes are not repaired
    // by guessing dimensions or expanding beyond the recorded active area.
    make_x_t5(raw);
    raw->makernotes.fuji.RAFDataGeneration = 0;
    expect_unchanged(raw, expected);
    make_x_t5(raw);
    raw->makernotes.fuji.RAFData_ImageSizeTable[1] = 0;
    expect_unchanged(raw, expected);
    make_x_t5(raw);
    raw->sizes.raw_height = 5178;
    expect_unchanged(raw, expected);
    make_x_t5(raw);
    raw->sizes.width = 7728;
    expect_unchanged(raw, expected);
    make_x_t5(raw);
    raw->sizes.top_margin = 12;
    expect_unchanged(raw, expected);

    make_x_t5_color(raw);
    memcpy(expected, raw, sizeof(*raw));
    memset(expected->color.cam_xyz, 0, sizeof(expected->color.cam_xyz));
    memset(expected->color.rgb_cam, 0, sizeof(expected->color.rgb_cam));
    for (int channel = 0; channel < 3; ++channel) {
        expected->color.pre_mul[channel] = 1.f;
        expected->color.rgb_cam[channel][channel] = 1.f;
    }
    expected->rawdata.color = expected->color;
    expected->rawdata.ioparams.raw_color = 1;
    fsc_restore_legacy_raw_color(raw);
    // In particular, camera WB, black level, and geometry must be retained.
    assert(memcmp(raw, expected, sizeof(*raw)) == 0);
    expect_unchanged(raw, expected);

    make_x_t5_color(raw);
    raw->color.cam_xyz[0][0] = 1.2f;
    expect_unchanged(raw, expected);
    make_x_t5_color(raw);
    raw->makernotes.fuji.CropMode = 2;
    expect_unchanged(raw, expected);
    make_x_t5_color(raw);
    raw->idata.dng_version = 0x01040000;
    expect_unchanged(raw, expected);

    free(expected);
    free(raw);
    puts("RAW decode compatibility checks passed.");
    return 0;
}
