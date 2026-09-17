#ifndef FSC_RAW_DECODE_COMPATIBILITY_H
#define FSC_RAW_DECODE_COMPATIBILITY_H

#include <libraw/libraw.h>
#include <string.h>

// LibRaw 0.22's new 7872-wide Fuji table moves the X-T5 active area 60
// columns left and removes six rows. Preserve the 0.21.4 source coordinates
// used by saved crops, previews, and the frozen export oracle. Apply after
// open, before unpack or size queries. Both operations can restore the saved
// rawdata geometry, so keep the two copies in sync.
// Match only the verified, uncropped X-T5 layout; leave other cameras, DNGs,
// camera crop modes, and any future layout changes to LibRaw.
static inline int fsc_is_legacy_x_t5(const libraw_data_t *raw) {
    return !(raw->idata.maker_index != LIBRAW_CAMERAMAKER_Fujifilm
        || strcmp(raw->idata.model, "X-T5") != 0
        || raw->idata.dng_version != 0 || raw->idata.filters != 9
        || raw->makernotes.fuji.CropMode != 0
        || raw->makernotes.fuji.RAFDataGeneration != 4
        || raw->makernotes.fuji.RAFData_ImageSizeTable[0] != 7752
        || raw->makernotes.fuji.RAFData_ImageSizeTable[1] != 5184
        || raw->sizes.raw_width != 7872 || raw->sizes.raw_height != 5196
    );
}

static inline void fsc_restore_legacy_raw_geometry(libraw_data_t *raw) {
    if (!fsc_is_legacy_x_t5(raw)
        || raw->sizes.width != 7752 || raw->sizes.height != 5178
        || raw->sizes.left_margin != 0 || raw->sizes.top_margin != 6) {
        return;
    }
    raw->sizes.left_margin = 60;
    raw->sizes.height = 5184;
    raw->sizes.iwidth = raw->sizes.width;
    raw->sizes.iheight = raw->sizes.height;
    raw->rawdata.sizes = raw->sizes;
    // Both origins are multiples of the six-pixel CFA period, so the
    // X-Trans pattern and the unpacked mosaic do not need modification.
}

// Call after unpack, which saves its internal raw_color flag into rawdata.
// LibRaw 0.21.4 had no X-T5 matrix: its camera-WB output is the authority for
// existing film looks and pixel fixtures. Only undo the known 0.22 matrix;
// a different matrix or source layout needs a fresh compatibility assessment.
static inline void fsc_restore_legacy_raw_color(libraw_data_t *raw) {
    static const float libraw_022_x_t5_xyz[4][3] = {
        {1.1809f, -0.5358f, -0.1141f},
        {-0.4248f, 1.2164f, 0.2343f},
        {-0.0514f, 0.1097f, 0.5848f},
        {0.f, 0.f, 0.f}
    };
    if (!fsc_is_legacy_x_t5(raw)
        || raw->sizes.width != 7752 || raw->sizes.height != 5184
        || raw->sizes.left_margin != 60 || raw->sizes.top_margin != 6
        || memcmp(raw->color.cam_xyz, libraw_022_x_t5_xyz,
                  sizeof(libraw_022_x_t5_xyz)) != 0) {
        return;
    }
    memset(raw->color.cam_xyz, 0, sizeof(raw->color.cam_xyz));
    memset(raw->color.rgb_cam, 0, sizeof(raw->color.rgb_cam));
    for (int channel = 0; channel < 4; ++channel) {
        raw->color.pre_mul[channel] = channel < 3 ? 1.f : 0.f;
        if (channel < 3) {
            raw->color.rgb_cam[channel][channel] = 1.f;
        }
    }
    raw->rawdata.color = raw->color;
    raw->rawdata.ioparams.raw_color = 1;
}

#endif
