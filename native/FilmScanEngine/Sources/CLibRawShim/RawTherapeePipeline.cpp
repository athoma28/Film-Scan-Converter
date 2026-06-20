/*
 * RawTherapee camera-scan bridge additions.
 * RCD is adapted from RawTherapee's GPLv3 rcd_demosaic.cc (Luis Sanz
 * Rodriguez and Ingo Weyrich). This project is GPLv3 as well.
 */
#include "CLibRawShim.h"

#include <libraw/libraw.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>

namespace {

template <typename T>
T limited(T value, T lower, T upper) {
    return std::max(lower, std::min(value, upper));
}

class FSCRawTherapeeDecoder final : public LibRaw {
public:
    bool usedRCD = false;
    bool usedXTransThreePass = false;

    FSCRawTherapeeDecoder() : LibRaw(LIBRAW_OPTIONS_NONE) {
        callbacks.interpolate_bayer_cb = &FSCRawTherapeeDecoder::rcdCallback;
        callbacks.interpolate_xtrans_cb = &FSCRawTherapeeDecoder::xtransCallback;
    }

private:
    static void rcdCallback(void *context) {
        static_cast<FSCRawTherapeeDecoder *>(context)->rcdDemosaic();
    }

    static void xtransCallback(void *context) {
        static_cast<FSCRawTherapeeDecoder *>(context)->xtransThreePassDemosaic();
    }

    void xtransThreePassDemosaic() {
        // LibRaw's X-Trans implementation is Markesteijn-derived. Three passes
        // trade decode time for the cleaner fine colour detail RawTherapee
        // recommends for final-quality X-Trans output.
        xtrans_interpolate(3);
        usedXTransThreePass = true;
    }

    int colorAt(int row, int col) const {
        const unsigned filters = imgdata.idata.filters;
        return (filters >> ((((row << 1) & 14) + (col & 1)) << 1)) & 3;
    }

    void rcdDemosaic() {
        const int width = imgdata.sizes.width;
        const int height = imgdata.sizes.height;
        if (!imgdata.image || width < 20 || height < 20 || imgdata.idata.filters <= 1000) {
            lin_interpolate();
            return;
        }
        for (int r = 0; r < 2; ++r) {
            for (int c = 0; c < 2; ++c) {
                if (colorAt(r, c) == 3) {
                    lin_interpolate();
                    return;
                }
            }
        }

        constexpr float eps = 1e-5f;
        constexpr float epssq = 1e-10f;
        auto sample = [&](int row, int col) -> float {
            const int channel = colorAt(row, col);
            return imgdata.image[row * width + col][channel] / 65535.f;
        };
        auto channel = [&](int row, int col, int c) -> float {
            return imgdata.image[row * width + col][c] / 65535.f;
        };
        auto put = [&](int row, int col, int c, float value) {
            imgdata.image[row * width + col][c] = static_cast<ushort>(
                limited(value, 0.f, 1.f) * 65535.f + 0.5f
            );
        };
        auto square = [](float value) { return value * value; };
        auto hpf = [&](int row, int col, int dr, int dc) {
            return square(
                sample(row - 3 * dr, col - 3 * dc)
                - sample(row - dr, col - dc)
                - sample(row + dr, col + dc)
                + sample(row + 3 * dr, col + 3 * dc)
                - 3.f * (sample(row - 2 * dr, col - 2 * dc)
                    + sample(row + 2 * dr, col + 2 * dc))
                + 6.f * sample(row, col)
            );
        };
        auto direction = [&](int row, int col, int dr1, int dc1, int dr2, int dc2) {
            float a = epssq;
            float b = epssq;
            for (int offset = -1; offset <= 1; ++offset) {
                a += hpf(row + offset * dr2, col + offset * dc2, dr1, dc1);
                b += hpf(row + offset * dr1, col + offset * dc1, dr2, dc2);
            }
            return a / (a + b);
        };
        auto lpf = [&](int row, int col) {
            return sample(row, col)
                + 0.5f * (sample(row - 1, col) + sample(row + 1, col)
                    + sample(row, col - 1) + sample(row, col + 1))
                + 0.25f * (sample(row - 1, col - 1) + sample(row - 1, col + 1)
                    + sample(row + 1, col - 1) + sample(row + 1, col + 1));
        };

        // Green at red/blue sites.
        for (int row = 5; row < height - 5; ++row) {
            for (int col = 5; col < width - 5; ++col) {
                const int c = colorAt(row, col);
                if (c == 1) { continue; }
                const float center = sample(row, col);
                const float nGrad = eps + std::fabs(sample(row - 1, col) - sample(row + 1, col))
                    + std::fabs(center - sample(row - 2, col))
                    + std::fabs(sample(row - 1, col) - sample(row - 3, col))
                    + std::fabs(sample(row - 2, col) - sample(row - 4, col));
                const float sGrad = eps + std::fabs(sample(row - 1, col) - sample(row + 1, col))
                    + std::fabs(center - sample(row + 2, col))
                    + std::fabs(sample(row + 1, col) - sample(row + 3, col))
                    + std::fabs(sample(row + 2, col) - sample(row + 4, col));
                const float wGrad = eps + std::fabs(sample(row, col - 1) - sample(row, col + 1))
                    + std::fabs(center - sample(row, col - 2))
                    + std::fabs(sample(row, col - 1) - sample(row, col - 3))
                    + std::fabs(sample(row, col - 2) - sample(row, col - 4));
                const float eGrad = eps + std::fabs(sample(row, col - 1) - sample(row, col + 1))
                    + std::fabs(center - sample(row, col + 2))
                    + std::fabs(sample(row, col + 1) - sample(row, col + 3))
                    + std::fabs(sample(row, col + 2) - sample(row, col + 4));
                const float lp = lpf(row, col);
                const float n = sample(row - 1, col) * (2.f * lp) / (eps + lp + lpf(row - 2, col));
                const float s = sample(row + 1, col) * (2.f * lp) / (eps + lp + lpf(row + 2, col));
                const float w = sample(row, col - 1) * (2.f * lp) / (eps + lp + lpf(row, col - 2));
                const float e = sample(row, col + 1) * (2.f * lp) / (eps + lp + lpf(row, col + 2));
                const float vertical = (sGrad * n + nGrad * s) / (nGrad + sGrad);
                const float horizontal = (wGrad * e + eGrad * w) / (eGrad + wGrad);
                const float central = direction(row, col, 1, 0, 0, 1);
                const float nearby = 0.25f * (
                    direction(row - 1, col - 1, 1, 0, 0, 1)
                    + direction(row - 1, col + 1, 1, 0, 0, 1)
                    + direction(row + 1, col - 1, 1, 0, 0, 1)
                    + direction(row + 1, col + 1, 1, 0, 0, 1));
                const float disc = std::fabs(0.5f - central) < std::fabs(0.5f - nearby)
                    ? nearby : central;
                put(row, col, 1, disc * horizontal + (1.f - disc) * vertical);
            }
        }

        // Opposite chroma at red/blue sites.
        for (int row = 5; row < height - 5; ++row) {
            for (int col = 5; col < width - 5; ++col) {
                const int source = colorAt(row, col);
                if (source == 1) { continue; }
                const int c = 2 - source;
                auto grad = [&](int dr, int dc) {
                    return eps + std::fabs(channel(row - dr, col - dc, c) - channel(row + dr, col + dc, c))
                        + std::fabs(channel(row - dr, col - dc, c) - channel(row - 3 * dr, col - 3 * dc, c))
                        + std::fabs(channel(row, col, 1) - channel(row - 2 * dr, col - 2 * dc, 1));
                };
                auto diff = [&](int dr, int dc) {
                    return channel(row + dr, col + dc, c) - channel(row + dr, col + dc, 1);
                };
                const float nwg = grad(1, 1), neg = grad(1, -1);
                const float swg = grad(-1, 1), seg = grad(-1, -1);
                const float p = (nwg * diff(1, 1) + seg * diff(-1, -1)) / (nwg + seg);
                const float q = (neg * diff(1, -1) + swg * diff(-1, 1)) / (neg + swg);
                const float disc = direction(row, col, 1, 1, 1, -1);
                put(row, col, c, channel(row, col, 1) + disc * q + (1.f - disc) * p);
            }
        }

        // Red and blue at green sites.
        for (int row = 5; row < height - 5; ++row) {
            for (int col = 5; col < width - 5; ++col) {
                if (colorAt(row, col) != 1) { continue; }
                const float disc = direction(row, col, 1, 0, 0, 1);
                for (int c = 0; c <= 2; c += 2) {
                    auto estimate = [&](int dr, int dc) {
                        return channel(row + dr, col + dc, c) - channel(row + dr, col + dc, 1);
                    };
                    const float nGrad = eps + std::fabs(channel(row, col, 1) - channel(row - 2, col, 1))
                        + std::fabs(channel(row - 1, col, c) - channel(row + 1, col, c));
                    const float sGrad = eps + std::fabs(channel(row, col, 1) - channel(row + 2, col, 1))
                        + std::fabs(channel(row - 1, col, c) - channel(row + 1, col, c));
                    const float wGrad = eps + std::fabs(channel(row, col, 1) - channel(row, col - 2, 1))
                        + std::fabs(channel(row, col - 1, c) - channel(row, col + 1, c));
                    const float eGrad = eps + std::fabs(channel(row, col, 1) - channel(row, col + 2, 1))
                        + std::fabs(channel(row, col - 1, c) - channel(row, col + 1, c));
                    const float vertical = (nGrad * estimate(1, 0) + sGrad * estimate(-1, 0)) / (nGrad + sGrad);
                    const float horizontal = (eGrad * estimate(0, -1) + wGrad * estimate(0, 1)) / (eGrad + wGrad);
                    put(row, col, c, channel(row, col, 1) + disc * horizontal + (1.f - disc) * vertical);
                }
            }
        }
        border_interpolate(5);
        usedRCD = true;
    }
};

void isoAdaptiveFilter(libraw_processed_image_t *image, float iso, uint32_t &flags) {
    if (!(iso > 0) || image->width < 3 || image->height < 3) { return; }
    auto *pixels = reinterpret_cast<uint16_t *>(image->data);
    const int width = image->width;
    const int height = image->height;
    if (iso < 800.f) {
        std::vector<uint16_t> previous(width * 3), current(width * 3), next(width * 3);
        std::memcpy(previous.data(), pixels, previous.size() * sizeof(uint16_t));
        std::memcpy(current.data(), pixels + width * 3, current.size() * sizeof(uint16_t));
        for (int row = 1; row < height - 1; ++row) {
            std::memcpy(next.data(), pixels + (row + 1) * width * 3, next.size() * sizeof(uint16_t));
            for (int col = 1; col < width - 1; ++col) {
                for (int c = 0; c < 3; ++c) {
                    const int i = col * 3 + c;
                    const double blur = (previous[i] + current[i - 3] + 4.0 * current[i]
                        + current[i + 3] + next[i]) / 8.0;
                    pixels[row * width * 3 + i] = static_cast<uint16_t>(
                        limited(current[i] + 0.18 * (current[i] - blur), 0.0, 65535.0));
                }
            }
            previous.swap(current);
            current.swap(next);
        }
        flags |= FSC_RAW_PROCESSING_ISO_SHARPEN;
        return;
    }
    const double blend = iso >= 3200.f ? 0.38 : 0.20;
    for (int c = 0; c < 3; ++c) {
        for (int row = 0; row < height; ++row) {
            for (int col = 1; col < width; ++col) {
                const size_t i = (static_cast<size_t>(row) * width + col) * 3 + c;
                pixels[i] = static_cast<uint16_t>((1.0 - blend) * pixels[i] + blend * pixels[i - 3]);
            }
            for (int col = width - 2; col >= 0; --col) {
                const size_t i = (static_cast<size_t>(row) * width + col) * 3 + c;
                pixels[i] = static_cast<uint16_t>((1.0 - blend) * pixels[i] + blend * pixels[i + 3]);
            }
        }
    }
    flags |= FSC_RAW_PROCESSING_ISO_DENOISE;
}

struct Cleanup { libraw_processed_image_t *processed; };

} // namespace

extern "C" int fsc_decode_rawtherapee_direct(
    const char *path, int full_resolution, fsc_raw_direct *output,
    char *error_message, size_t error_capacity
) {
    std::unique_ptr<FSCRawTherapeeDecoder> raw(new FSCRawTherapeeDecoder());
    int code = raw->open_file(path);
    if (code != LIBRAW_SUCCESS) {
        std::snprintf(error_message, error_capacity, "%s", libraw_strerror(code));
        return code;
    }
    auto &p = raw->imgdata.params;
    p.output_bps = 16; p.use_camera_wb = 1; p.user_qual = 2;
    p.output_color = 1; p.gamm[0] = 1.0 / 2.4; p.gamm[1] = 12.92;
    p.no_auto_bright = 1; p.highlight = 3; p.half_size = full_resolution ? 0 : 1;
    p.adjust_maximum_thr = 0.75f; p.bright = 1.f; p.exp_correc = 0;
    code = raw->unpack();
    if (code == LIBRAW_SUCCESS) { code = raw->dcraw_process(); }
    if (code != LIBRAW_SUCCESS) {
        std::snprintf(error_message, error_capacity, "%s", libraw_strerror(code));
        return code;
    }
    int imageError = LIBRAW_SUCCESS;
    libraw_processed_image_t *processed = raw->dcraw_make_mem_image(&imageError);
    if (!processed || imageError != LIBRAW_SUCCESS || processed->bits != 16 || processed->colors != 3) {
        if (processed) { libraw_dcraw_clear_mem(processed); }
        std::snprintf(error_message, error_capacity, "LibRaw returned an invalid camera-scan image.");
        return imageError == LIBRAW_SUCCESS ? -1 : imageError;
    }
    uint32_t flags = 0;
    if (raw->usedRCD) { flags |= FSC_RAW_PROCESSING_RCD; }
    if (raw->usedXTransThreePass) { flags |= FSC_RAW_PROCESSING_XTRANS_THREE_PASS; }
    isoAdaptiveFilter(processed, raw->imgdata.other.iso_speed, flags);
    output->width = processed->width; output->height = processed->height;
    output->channels = processed->colors;
    output->pixel_count = static_cast<size_t>(processed->width) * processed->height * 3;
    output->bgr_pixels = reinterpret_cast<const uint16_t *>(processed->data);
    output->iso_speed = raw->imgdata.other.iso_speed;
    output->processing_flags = flags;
    std::snprintf(output->color_description, sizeof(output->color_description), "sRGB");
    auto *cleanup = static_cast<Cleanup *>(std::malloc(sizeof(Cleanup)));
    if (!cleanup) { libraw_dcraw_clear_mem(processed); return -1; }
    cleanup->processed = processed; output->_internal = cleanup;
    return LIBRAW_SUCCESS;
}
