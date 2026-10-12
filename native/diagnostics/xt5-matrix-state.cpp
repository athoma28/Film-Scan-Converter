// Read-only metadata probe for the X-T5 upstream matrix experiment.
// Uses the production compatibility helpers, but does not process/export pixels.
// Exit 2 means at least one frame failed decode or did not exercise the expected
// compatibility restoration. This is evidence about decoder policy, not quality.
#include "../FilmScanEngine/Sources/CLibRawShim/RawDecodeCompatibility.h"

#include <cmath>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>

namespace {

std::string quoted(const char *value) {
    std::ostringstream out;
    out << '"';
    for (const unsigned char c : std::string(value ? value : "")) {
        switch (c) {
        case '"': out << "\\\""; break;
        case '\\': out << "\\\\"; break;
        case '\b': out << "\\b"; break;
        case '\f': out << "\\f"; break;
        case '\n': out << "\\n"; break;
        case '\r': out << "\\r"; break;
        case '\t': out << "\\t"; break;
        default:
            if (c < 0x20) {
                out << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                    << static_cast<unsigned>(c) << std::dec;
            } else {
                out << c;
            }
        }
    }
    return out.str() + '"';
}

template <typename T>
void array(const T *values, size_t count) {
    std::cout << '[';
    for (size_t i = 0; i < count; ++i) {
        if (i) std::cout << ',';
        const double value = static_cast<double>(values[i]);
        if (std::isfinite(value)) std::cout << value;
        else std::cout << "null";
    }
    std::cout << ']';
}

template <size_t Rows, size_t Columns>
void matrix(const float (&values)[Rows][Columns]) {
    std::cout << '[';
    for (size_t row = 0; row < Rows; ++row) {
        if (row) std::cout << ',';
        array(values[row], Columns);
    }
    std::cout << ']';
}

void geometry(const libraw_image_sizes_t &sizes) {
    std::cout << "{\"rawWidth\":" << sizes.raw_width
        << ",\"rawHeight\":" << sizes.raw_height
        << ",\"width\":" << sizes.width << ",\"height\":" << sizes.height
        << ",\"leftMargin\":" << sizes.left_margin
        << ",\"topMargin\":" << sizes.top_margin
        << ",\"interpolatedWidth\":" << sizes.iwidth
        << ",\"interpolatedHeight\":" << sizes.iheight << '}';
}

void color(const libraw_colordata_t &data, unsigned rawColor) {
    std::cout << "{\"camXYZ\":";
    matrix(data.cam_xyz);
    std::cout << ",\"rgbCam\":";
    matrix(data.rgb_cam);
    std::cout << ",\"preMultipliers\":";
    array(data.pre_mul, 4);
    std::cout << ",\"cameraWhiteBalance\":";
    array(data.cam_mul, 4);
    std::cout << ",\"rawColor\":" << rawColor
        << ",\"black\":" << data.black << ",\"channelBlack\":";
    array(data.cblack, 4);
    std::cout << ",\"blackPatternRows\":" << data.cblack[4]
        << ",\"blackPatternColumns\":" << data.cblack[5]
        << ",\"maximum\":" << data.maximum
        << ",\"dataMaximum\":" << data.data_maximum << '}';
}

bool expectedUpstreamMatrix(const libraw_colordata_t &color) {
    const float expected[4][3] = {
        {1.1809f, -0.5358f, -0.1141f},
        {-0.4248f, 1.2164f, 0.2343f},
        {-0.0514f, 0.1097f, 0.5848f},
        {0.f, 0.f, 0.f}
    };
    return std::memcmp(color.cam_xyz, expected, sizeof(expected)) == 0;
}

bool sameGeometry(const libraw_image_sizes_t &a, const libraw_image_sizes_t &b) {
    return a.raw_width == b.raw_width && a.raw_height == b.raw_height
        && a.width == b.width && a.height == b.height
        && a.left_margin == b.left_margin && a.top_margin == b.top_margin
        && a.iwidth == b.iwidth && a.iheight == b.iheight;
}

bool frame(const char *path) {
    LibRaw decoder;
    auto &raw = decoder.imgdata;
    std::cout << "{\"path\":" << quoted(path);
    int result = decoder.open_file(path);
    if (result != LIBRAW_SUCCESS) {
        std::cout << ",\"errorStage\":\"open\",\"error\":"
            << quoted(libraw_strerror(result)) << '}';
        return false;
    }
    const auto openedGeometry = raw.sizes;
    fsc_restore_legacy_raw_geometry(&raw);
    const auto restoredGeometry = raw.sizes;
    std::cout << ",\"make\":" << quoted(raw.idata.make)
        << ",\"model\":" << quoted(raw.idata.model)
        << ",\"filters\":" << raw.idata.filters
        << ",\"dngVersion\":" << raw.idata.dng_version
        << ",\"cropMode\":" << raw.makernotes.fuji.CropMode
        << ",\"rafDataGeneration\":" << raw.makernotes.fuji.RAFDataGeneration
        << ",\"openedGeometry\":";
    geometry(openedGeometry);
    std::cout << ",\"restoredGeometry\":";
    geometry(restoredGeometry);
    std::cout << ",\"geometryRestorationApplied\":"
        << (!sameGeometry(openedGeometry, restoredGeometry) ? "true" : "false");

    result = decoder.unpack();
    if (result != LIBRAW_SUCCESS) {
        std::cout << ",\"errorStage\":\"unpack\",\"error\":"
            << quoted(libraw_strerror(result)) << '}';
        return false;
    }
    const auto beforeColor = raw.color;
    const auto unpackedGeometry = raw.sizes;
    const unsigned beforeRawColor = raw.rawdata.ioparams.raw_color;
    const bool layoutMatched = fsc_is_legacy_x_t5(&raw);
    const bool matrixMatched = expectedUpstreamMatrix(beforeColor);
    fsc_restore_legacy_raw_color(&raw);
    const bool restorationApplied =
        std::memcmp(beforeColor.cam_xyz, raw.color.cam_xyz,
                    sizeof(beforeColor.cam_xyz)) != 0;
    const bool geometryPreserved = sameGeometry(unpackedGeometry, raw.sizes)
        && sameGeometry(restoredGeometry, raw.sizes);
    const bool wbAndLevelsPreserved =
        std::memcmp(beforeColor.cam_mul, raw.color.cam_mul,
                    sizeof(beforeColor.cam_mul)) == 0
        && std::memcmp(beforeColor.cblack, raw.color.cblack,
                       sizeof(beforeColor.cblack)) == 0
        && beforeColor.black == raw.color.black
        && beforeColor.maximum == raw.color.maximum
        && beforeColor.data_maximum == raw.color.data_maximum;
    std::cout << ",\"knownLayoutMatched\":" << (layoutMatched ? "true" : "false")
        << ",\"knownMatrixMatched\":" << (matrixMatched ? "true" : "false")
        << ",\"colorRestorationApplied\":" << (restorationApplied ? "true" : "false")
        << ",\"geometryPreserved\":" << (geometryPreserved ? "true" : "false")
        << ",\"whiteBalanceAndBlackMaximumPreserved\":"
        << (wbAndLevelsPreserved ? "true" : "false")
        << ",\"upstreamColorBeforeRestoration\":";
    color(beforeColor, beforeRawColor);
    std::cout << ",\"legacyColorAfterRestoration\":";
    color(raw.color, raw.rawdata.ioparams.raw_color);
    std::cout << '}';
    return layoutMatched && matrixMatched && restorationApplied
        && geometryPreserved && wbAndLevelsPreserved;
}

} // namespace

int main(int argc, char **argv) {
    if (argc < 2) {
        std::cerr << "Usage: xt5-matrix-state RAW [RAW ...]\n";
        return 1;
    }
    std::cout << std::setprecision(17)
        << "{\"schemaVersion\":1,\"librawVersion\":" << quoted(LibRaw::version())
        << ",\"scope\":\"open-and-unpack-only; no color processing or pixels exported\""
        << ",\"frames\":[";
    bool passed = true;
    for (int i = 1; i < argc; ++i) {
        if (i > 1) std::cout << ',';
        const bool framePassed = frame(argv[i]);
        passed = passed && framePassed;
        std::cerr << (framePassed ? "PASS " : "FAIL ") << argv[i] << '\n';
        std::cout.flush();
    }
    std::cout << "],\"allFramesMatched\":" << (passed ? "true" : "false") << "}\n";
    return passed ? 0 : 2;
}
