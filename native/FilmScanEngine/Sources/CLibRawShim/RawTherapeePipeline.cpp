/*
 * RawTherapee camera-scan bridge additions.
 * RCD is adapted from RawTherapee's GPLv3 rcd_demosaic.cc (Luis Sanz
 * Rodriguez and Ingo Weyrich). This project is GPLv3 as well.
 */
#include "CLibRawShim.h"

#include <libraw/libraw.h>
#include <dispatch/dispatch.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cfloat>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

// CommonCrypto is part of the OS, so stage hashing adds no packaged
// dependency. The C API is deprecated in favor of Swift CryptoKit, which is
// not reachable from this C++ target.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include <CommonCrypto/CommonDigest.h>

namespace {

// Incremental SHA-256 over stage-boundary buffers. Metadata is hashed as raw
// POD bytes: digests compare runs of the same build on the same machine, so
// endianness stability across platforms is not required.
class StageHasher {
public:
    StageHasher() { CC_SHA256_Init(&context_); }

    template <typename T>
    void pod(T value) {
        CC_SHA256_Update(&context_, &value, sizeof(value));
    }

    void bytes(const void *data, size_t length) {
        const auto *cursor = static_cast<const uint8_t *>(data);
        while (length > 0) {
            const CC_LONG chunk = static_cast<CC_LONG>(
                std::min<size_t>(length, 64 * 1024 * 1024));
            CC_SHA256_Update(&context_, cursor, chunk);
            cursor += chunk;
            length -= chunk;
        }
    }

    void hexDigest(char output[FSC_RAW_STAGE_HASH_HEX_SIZE]) {
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256_Final(digest, &context_);
        static const char kHex[] = "0123456789abcdef";
        for (int index = 0; index < CC_SHA256_DIGEST_LENGTH; ++index) {
            output[index * 2] = kHex[digest[index] >> 4];
            output[index * 2 + 1] = kHex[digest[index] & 0xF];
        }
        output[CC_SHA256_DIGEST_LENGTH * 2] = '\0';
    }

private:
    CC_SHA256_CTX context_;
};

#pragma clang diagnostic pop

template <typename T>
T limited(T value, T lower, T upper) {
    return std::max(lower, std::min(value, upper));
}

int configuredWorkerCount(const char *environmentName) {
    constexpr int maximumWorkers = 8;
    int workers = limited(static_cast<int>(std::thread::hardware_concurrency()), 1, maximumWorkers);
    const char *overrideValue = std::getenv(environmentName);
    if (!overrideValue || !*overrideValue) { return workers; }
    char *end = nullptr;
    const long parsed = std::strtol(overrideValue, &end, 10);
    if (end == overrideValue || *end != '\0' || parsed < 1 || parsed > maximumWorkers) {
        return workers;
    }
    return static_cast<int>(parsed);
}

// LibRaw's stock file/buffer streams leave lock()/unlock() as no-ops. The
// compressed Fuji decoder already calls those around seek+read, which is how
// independent strips stay exact when OpenMP is off. This wrapper supplies the
// missing critical section without enabling LIBRAW_FORCE_OPENMP.
class FSCLockingDatastream final : public LibRaw_abstract_datastream {
public:
    FSCLockingDatastream(LibRaw_abstract_datastream *inner, bool ownsInner)
        : inner_(inner), ownsInner_(ownsInner) {}

    ~FSCLockingDatastream() override {
        if (ownsInner_) { delete inner_; }
    }

    int valid() override { return inner_->valid(); }
    int read(void *ptr, size_t size, size_t nmemb) override {
        return inner_->read(ptr, size, nmemb);
    }
    int seek(INT64 offset, int whence) override { return inner_->seek(offset, whence); }
    INT64 tell() override { return inner_->tell(); }
    INT64 size() override { return inner_->size(); }
    int get_char() override { return inner_->get_char(); }
    char *gets(char *str, int size) override { return inner_->gets(str, size); }
    int scanf_one(const char *fmt, void *value) override {
        return inner_->scanf_one(fmt, value);
    }
    int eof() override { return inner_->eof(); }
    int jpeg_src(void *jpegdata) override { return inner_->jpeg_src(jpegdata); }
    void buffering_off() override { inner_->buffering_off(); }
    int lock() override {
        mutex_.lock();
        return 1;
    }
    void unlock() override { mutex_.unlock(); }
    const char *fname() override { return inner_->fname(); }

private:
    LibRaw_abstract_datastream *inner_;
    bool ownsInner_;
    std::mutex mutex_;
};

class FSCRawTherapeeDecoder final : public LibRaw {
public:
    bool usedRCD = false;
    bool usedXTransThreePass = false;
    bool usedDeterministicParallelXTrans = false;
    bool usedParallelFujiUnpack = false;
    int xtransWorkerCount = 1;
    int unpackWorkerCount = 1;
    double demosaicSeconds = 0;
    double stageHashSeconds = 0;
    // Opt-in stage-boundary digest capture. When set, the demosaic callbacks
    // hash imgdata.image immediately after interpolation returns.
    fsc_raw_stage_hashes *stageHashes = nullptr;

    explicit FSCRawTherapeeDecoder(bool fullResolution)
        : LibRaw(LIBRAW_OPTIONS_NONE), xtransPasses(fullResolution ? 3 : 1) {
        callbacks.interpolate_bayer_cb = &FSCRawTherapeeDecoder::rcdCallback;
        callbacks.interpolate_xtrans_cb = &FSCRawTherapeeDecoder::xtransCallback;
    }

private:
    const int xtransPasses;
    bool ioLockInstalled = false;

    static void rcdCallback(void *context) {
        static_cast<FSCRawTherapeeDecoder *>(context)->rcdDemosaic();
    }

    static void xtransCallback(void *context) {
        static_cast<FSCRawTherapeeDecoder *>(context)->xtransDemosaic();
    }

    void xtransDemosaic() {
        // LibRaw's X-Trans implementation is Markesteijn-derived. Three passes
        // trade decode time for the cleaner fine colour detail RawTherapee
        // recommends for final-quality X-Trans output. Preserve the upstream
        // pixel arithmetic and overlapping-tile dependence, including the
        // 16-pixel halo that can read the above-right neighbor, then run
        // independent 2*row+col wavefront diagonals concurrently.
        const auto start = std::chrono::steady_clock::now();
        if (imgdata.sizes.width < LIBRAW_AHD_TILE
            || imgdata.sizes.height < LIBRAW_AHD_TILE)
        {
            // The interpolator rejects frames smaller than one AHD tile
            // (512px). Linear interpolation keeps camera WB and colour matrix
            // so a colour-accurate draft can still render quickly.
            lin_interpolate();
        } else {
            deterministicParallelXTransInterpolate(xtransPasses);
            usedXTransThreePass = xtransPasses == 3;
        }
        demosaicSeconds = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - start).count();
        hashDemosaicedIfRequested();
    }

    static int configuredXTransWorkerCount() {
        return configuredWorkerCount("FSC_XTRANS_WORKERS");
    }

    void installIOLock() {
        if (ioLockInstalled) { return; }
        auto &id = libraw_internal_data.internal_data;
        if (!id.input) { return; }
        auto *wrapper = new FSCLockingDatastream(id.input, id.input_internal != 0);
        id.input = wrapper;
        id.input_internal = 1;
        ioLockInstalled = true;
    }

    // LibRaw documents fuji_decode_loop as the public hook for a parallel
    // Fuji compressed decoder. Independent strips write disjoint mosaic
    // columns. Do not enable LIBRAW_FORCE_OPENMP: that also turns on the racy
    // overlapping X-Trans tile loop.
    void fuji_decode_loop(
        fuji_compressed_params *common_info,
        int count,
        INT64 *offsets,
        unsigned *sizes,
        uchar *q_bases
    ) override {
        const int configured = configuredWorkerCount("FSC_UNPACK_WORKERS");
        const int workerCount = limited(configured, 1, std::max(1, count));
        unpackWorkerCount = workerCount;
        usedParallelFujiUnpack = workerCount > 1;
        if (!usedParallelFujiUnpack) {
            LibRaw::fuji_decode_loop(common_info, count, offsets, sizes, q_bases);
            return;
        }

        installIOLock();
        const int lineStep =
            (libraw_internal_data.unpacker_data.fuji_total_lines + 0xF) & ~0xF;
        std::atomic<int> errorCode{LIBRAW_EXCEPTION_NONE};
        struct Context {
            FSCRawTherapeeDecoder *decoder;
            fuji_compressed_params *commonInfo;
            int count;
            int workerCount;
            int lineStep;
            INT64 *offsets;
            unsigned *sizes;
            uchar *qBases;
            std::atomic<int> *errorCode;
        } context = {
            this, common_info, count, workerCount, lineStep,
            offsets, sizes, q_bases, &errorCode
        };
        dispatch_apply_f(
            static_cast<size_t>(workerCount),
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
            &context,
            [](void *rawContext, size_t workerIndex) {
                auto *context = static_cast<Context *>(rawContext);
                for (int block = static_cast<int>(workerIndex);
                     block < context->count;
                     block += context->workerCount) {
                    if (context->errorCode->load() != LIBRAW_EXCEPTION_NONE) {
                        return;
                    }
                    try {
                        context->decoder->fuji_decode_strip(
                            context->commonInfo,
                            block,
                            context->offsets[block],
                            context->sizes[block],
                            context->qBases
                                ? context->qBases + block * context->lineStep
                                : nullptr);
                    } catch (const LibRaw_exceptions exception) {
                        int expected = LIBRAW_EXCEPTION_NONE;
                        context->errorCode->compare_exchange_strong(
                            expected, static_cast<int>(exception));
                    } catch (...) {
                        int expected = LIBRAW_EXCEPTION_NONE;
                        context->errorCode->compare_exchange_strong(
                            expected, LIBRAW_EXCEPTION_DECODE_RAW);
                    }
                }
            });
        const int error = errorCode.load();
        if (error != LIBRAW_EXCEPTION_NONE) {
            throw static_cast<LibRaw_exceptions>(error);
        }
    }

    static char **allocateXTransBuffers(int count, size_t size) {
        auto **buffers = static_cast<char **>(std::calloc(count, sizeof(char *)));
        if (!buffers) { throw LIBRAW_EXCEPTION_ALLOC; }
        for (int index = 0; index < count; ++index) {
            buffers[index] = static_cast<char *>(std::calloc(size, 1));
            if (!buffers[index]) {
                for (int allocated = 0; allocated < index; ++allocated) {
                    std::free(buffers[allocated]);
                }
                std::free(buffers);
                throw LIBRAW_EXCEPTION_ALLOC;
            }
        }
        return buffers;
    }

    static void releaseXTransBuffers(char **buffers, int count) {
        if (!buffers) { return; }
        for (int index = 0; index < count; ++index) { std::free(buffers[index]); }
        std::free(buffers);
    }

    template <typename TileFunction>
    void parallelXTransWavefront(
        const std::vector<int> &tops,
        const std::vector<int> &lefts,
        char **buffers,
        int bufferCount,
        TileFunction processTile
    ) {
        const int rowTiles = static_cast<int>(tops.size());
        const int colTiles = static_cast<int>(lefts.size());
        if (rowTiles <= 0 || colTiles <= 0 || bufferCount <= 0 || !buffers) {
            return;
        }

        const auto runTile = [&](int row, int col, int bufferIndex) {
            processTile(tops[static_cast<size_t>(row)], lefts[static_cast<size_t>(col)],
                buffers[bufferIndex]);
        };

        if (xtransWorkerCount <= 1 || bufferCount <= 1) {
            for (int row = 0; row < rowTiles; ++row) {
                for (int col = 0; col < colTiles; ++col) { runTile(row, col, 0); }
            }
            return;
        }

        std::vector<int> diagRows;
        std::vector<int> diagCols;
        diagRows.reserve(static_cast<size_t>(std::min(rowTiles, colTiles)));
        diagCols.reserve(diagRows.capacity());
        // Overlapping 512-pixel tiles step by 496, so each tile's 16-pixel halo
        // can read the above-right neighbor's final write. A (row+col) diagonal
        // would run those two together. 2*row+col keeps left, above, above-left,
        // and above-right on earlier diagonals while still exposing independent
        // tiles to the worker pool.
        const int lastDiag = 2 * (rowTiles - 1) + (colTiles - 1);
        for (int diag = 0; diag <= lastDiag; ++diag) {
            diagRows.clear();
            diagCols.clear();
            for (int row = 0; row < rowTiles; ++row) {
                const int col = diag - 2 * row;
                if (col >= 0 && col < colTiles) {
                    diagRows.push_back(row);
                    diagCols.push_back(col);
                }
            }
            const int tileCount = static_cast<int>(diagRows.size());
            const int workerCount = std::min(
                std::min(xtransWorkerCount, bufferCount), tileCount);
            if (workerCount <= 1) {
                for (int tile = 0; tile < tileCount; ++tile) {
                    runTile(diagRows[static_cast<size_t>(tile)],
                        diagCols[static_cast<size_t>(tile)], 0);
                }
                continue;
            }
            struct Context {
                const std::vector<int> *diagRows;
                const std::vector<int> *diagCols;
                int workerCount;
                int tileCount;
                char **buffers;
                TileFunction *processTile;
                const std::vector<int> *tops;
                const std::vector<int> *lefts;
            } context = {
                &diagRows, &diagCols, workerCount, tileCount, buffers,
                &processTile, &tops, &lefts
            };
            dispatch_apply_f(
                static_cast<size_t>(workerCount),
                dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
                &context,
                [](void *rawContext, size_t workerIndex) {
                    auto *context = static_cast<Context *>(rawContext);
                    for (int tile = static_cast<int>(workerIndex);
                         tile < context->tileCount;
                         tile += context->workerCount) {
                        const int row = (*context->diagRows)[static_cast<size_t>(tile)];
                        const int col = (*context->diagCols)[static_cast<size_t>(tile)];
                        (*context->processTile)(
                            (*context->tops)[static_cast<size_t>(row)],
                            (*context->lefts)[static_cast<size_t>(col)],
                            context->buffers[workerIndex]);
                    }
                });
        }
    }

    // The included implementation preserves LibRaw 0.21.4's arithmetic and the
    // overlapping-tile dependence chain. Independent wavefront diagonals use
    // the bounded helper above; work inside a tile stays serial.
    void deterministicParallelXTransInterpolate(int passes) {
        xtransWorkerCount = configuredXTransWorkerCount();
        usedDeterministicParallelXTrans = xtransWorkerCount > 1;
#define fcol(row, col) xtrans[(row + 6) % 6][(col + 6) % 6]
#define image (imgdata.image)
#define xtrans (imgdata.idata.xtrans)
#define height (imgdata.sizes.height)
#define width (imgdata.sizes.width)
#define FORC(count) for (c = 0; c < count; c++)
#define FORC3 FORC(3)
#define FORC4 FORC(4)
#define SQR(value) ((value) * (value))
#define ABS(value) (((int)(value) ^ ((int)(value) >> 31)) - ((int)(value) >> 31))
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define LIM(value, lower, upper) MAX(lower, MIN(value, upper))
#define CLIP(value) LIM((int)(value), 0, 65535)
#define malloc_omp_buffers allocateXTransBuffers
#define free_omp_buffers releaseXTransBuffers
#include "XTransDemosaicBody.inc"
#undef free_omp_buffers
#undef malloc_omp_buffers
#undef CLIP
#undef LIM
#undef MAX
#undef MIN
#undef ABS
#undef SQR
#undef FORC4
#undef FORC3
#undef FORC
#undef width
#undef height
#undef xtrans
#undef image
#undef fcol
    }

    int colorAt(int row, int col) const {
        const unsigned filters = imgdata.idata.filters;
        return (filters >> ((((row << 1) & 14) + (col & 1)) << 1)) & 3;
    }

    // Boundary 2 of the stage-digest contract: imgdata.image immediately
    // after interpolation returns, before the remaining dcraw_process stages.
    void hashDemosaicedIfRequested() {
        if (!stageHashes) { return; }
        const int width = imgdata.sizes.width;
        const int height = imgdata.sizes.height;
        if (!imgdata.image || width <= 0 || height <= 0) { return; }
        const auto start = std::chrono::steady_clock::now();
        StageHasher hasher;
        hasher.pod(static_cast<uint32_t>(width));
        hasher.pod(static_cast<uint32_t>(height));
        hasher.pod(imgdata.idata.filters);
        hasher.bytes(
            imgdata.image,
            static_cast<size_t>(width) * static_cast<size_t>(height) * 4 * sizeof(ushort));
        hasher.hexDigest(stageHashes->demosaiced_sha256);
        stageHashSeconds += std::chrono::duration<double>(
            std::chrono::steady_clock::now() - start).count();
    }

    void rcdDemosaic() {
        const auto start = std::chrono::steady_clock::now();
        const int width = imgdata.sizes.width;
        const int height = imgdata.sizes.height;
        if (!imgdata.image || width < 20 || height < 20 || imgdata.idata.filters <= 1000) {
            lin_interpolate();
            hashDemosaicedIfRequested();
            return;
        }
        for (int r = 0; r < 2; ++r) {
            for (int c = 0; c < 2; ++c) {
                if (colorAt(r, c) == 3) {
                    lin_interpolate();
                    hashDemosaicedIfRequested();
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
        demosaicSeconds = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - start).count();
        usedRCD = true;
        hashDemosaicedIfRequested();
    }
};

// Boundary 1 of the stage-digest contract: the unpacked single-channel mosaic
// plus the dimensions and CFA metadata that describe it.
void hashUnpackedMosaic(LibRaw &raw, fsc_raw_stage_hashes *hashes) {
    auto &idata = raw.imgdata.idata;
    auto &sizes = raw.imgdata.sizes;
    hashes->mosaic_raw_width = sizes.raw_width;
    hashes->mosaic_raw_height = sizes.raw_height;
    hashes->mosaic_filters = idata.filters;
    const bool isXTrans = idata.filters == 9;
    hashes->mosaic_cfa_bytes = isXTrans ? 36 : 0;

    StageHasher hasher;
    hasher.pod(hashes->mosaic_raw_width);
    hasher.pod(hashes->mosaic_raw_height);
    hasher.pod(hashes->mosaic_filters);
    if (isXTrans) {
        hasher.bytes(idata.xtrans, 36);
    }
    const size_t photosites =
        static_cast<size_t>(sizes.raw_width) * static_cast<size_t>(sizes.raw_height);
    if (!raw.imgdata.rawdata.raw_image || photosites == 0) { return; }
    hasher.bytes(raw.imgdata.rawdata.raw_image, photosites * sizeof(ushort));
    hasher.hexDigest(hashes->unpacked_mosaic_sha256);
}

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

size_t rgb16PixelBytes(const libraw_processed_image_t *image) {
    return static_cast<size_t>(image->width)
        * static_cast<size_t>(image->height)
        * 3
        * sizeof(uint16_t);
}

bool isValidRGB16Bitmap(const libraw_processed_image_t *image) {
    return image
        && image->type == LIBRAW_IMAGE_BITMAP
        && image->width > 0
        && image->height > 0
        && image->bits == 16
        && image->colors == 3
        && image->data_size == rgb16PixelBytes(image);
}

// Bin the visible mosaic by an integer number of CFA periods so interpolation
// can run at the preview bound. Same-CFA photosites are averaged; the 6x6
// X-Trans or 2x2 Bayer pattern is preserved. Full-resolution export never
// calls this.
bool shrinkMosaicToBound(LibRaw &raw, int maxDimension) {
    auto &sizes = raw.imgdata.sizes;
    ushort *rawImage = raw.imgdata.rawdata.raw_image;
    if (!rawImage || maxDimension <= 0) { return false; }

    const int visibleWidth = sizes.width;
    const int visibleHeight = sizes.height;
    if (visibleWidth <= 0 || visibleHeight <= 0) { return false; }
    const int longest = std::max(visibleWidth, visibleHeight);
    if (longest <= maxDimension) { return false; }

    const bool isXTrans = raw.imgdata.idata.filters == 9;
    if (!isXTrans && raw.imgdata.idata.filters == 0) { return false; }
    const int period = isXTrans ? 6 : 2;
    const int factor = (longest + maxDimension - 1) / maxDimension;
    if (factor < 2) { return false; }

    const int tilesX = visibleWidth / period;
    const int tilesY = visibleHeight / period;
    const int outTilesX = tilesX / factor;
    const int outTilesY = tilesY / factor;
    if (outTilesX < 2 || outTilesY < 2) { return false; }

    const int outW = outTilesX * period;
    const int outH = outTilesY * period;
    const unsigned srcPitch =
        sizes.raw_pitch > 0 ? sizes.raw_pitch / static_cast<unsigned>(sizeof(ushort))
                            : static_cast<unsigned>(sizes.raw_width);
    const int left = sizes.left_margin;
    const int top = sizes.top_margin;
    std::vector<ushort> shrunk(static_cast<size_t>(outW) * static_cast<size_t>(outH));
    const uint32_t samples = static_cast<uint32_t>(factor) * static_cast<uint32_t>(factor);
    const uint32_t rounding = samples / 2;

    for (int ty = 0; ty < outTilesY; ++ty) {
        for (int tx = 0; tx < outTilesX; ++tx) {
            for (int py = 0; py < period; ++py) {
                for (int px = 0; px < period; ++px) {
                    uint32_t sum = 0;
                    for (int fy = 0; fy < factor; ++fy) {
                        for (int fx = 0; fx < factor; ++fx) {
                            const int iy = top + (ty * factor + fy) * period + py;
                            const int ix = left + (tx * factor + fx) * period + px;
                            sum += rawImage[static_cast<size_t>(iy) * srcPitch + static_cast<size_t>(ix)];
                        }
                    }
                    shrunk[(static_cast<size_t>(ty * period + py) * outW)
                        + static_cast<size_t>(tx * period + px)] =
                        static_cast<ushort>((sum + rounding) / samples);
                }
            }
        }
    }

    std::memcpy(rawImage, shrunk.data(), shrunk.size() * sizeof(ushort));
    sizes.raw_width = static_cast<ushort>(outW);
    sizes.raw_height = static_cast<ushort>(outH);
    sizes.raw_pitch = static_cast<unsigned>(outW) * static_cast<unsigned>(sizeof(ushort));
    sizes.width = static_cast<ushort>(outW);
    sizes.height = static_cast<ushort>(outH);
    sizes.iwidth = static_cast<ushort>(outW);
    sizes.iheight = static_cast<ushort>(outH);
    sizes.left_margin = 0;
    sizes.top_margin = 0;
    sizes.raw_inset_crops[0] = {0, 0, 0, 0};
    sizes.raw_inset_crops[1] = {0, 0, 0, 0};
    // dcraw_process restores sizes from this backup at raw2image_start().
    raw.imgdata.rawdata.sizes = sizes;
    return true;
}

libraw_processed_image_t *downsampleTwoByTwo(libraw_processed_image_t *source) {
    const unsigned outputWidth = source->width / 2;
    const unsigned outputHeight = source->height / 2;
    const size_t componentCount = static_cast<size_t>(outputWidth) * outputHeight * 3;
    const size_t dataSize = componentCount * sizeof(uint16_t);
    auto *output = static_cast<libraw_processed_image_t *>(
        std::malloc(sizeof(libraw_processed_image_t) + dataSize - 1));
    if (!output) { return nullptr; }

    output->type = LIBRAW_IMAGE_BITMAP;
    output->height = static_cast<ushort>(outputHeight);
    output->width = static_cast<ushort>(outputWidth);
    output->colors = 3;
    output->bits = 16;
    output->data_size = static_cast<unsigned>(dataSize);
    const auto *input = reinterpret_cast<const uint16_t *>(source->data);
    auto *pixels = reinterpret_cast<uint16_t *>(output->data);
    for (unsigned y = 0; y < outputHeight; ++y) {
        for (unsigned x = 0; x < outputWidth; ++x) {
            const size_t destination = (static_cast<size_t>(y) * outputWidth + x) * 3;
            const size_t topLeft = (static_cast<size_t>(y * 2) * source->width + x * 2) * 3;
            const size_t bottomLeft = topLeft + static_cast<size_t>(source->width) * 3;
            for (int channel = 0; channel < 3; ++channel) {
                const uint32_t sum = input[topLeft + channel]
                    + input[topLeft + 3 + channel]
                    + input[bottomLeft + channel]
                    + input[bottomLeft + 3 + channel];
                pixels[destination + channel] = static_cast<uint16_t>((sum + 2) / 4);
            }
        }
    }
    return output;
}

} // namespace

extern "C" int fsc_decode_rawtherapee_direct(
    const char *path, int full_resolution, int max_dimension, fsc_raw_direct *output,
    fsc_raw_stage_hashes *stage_hashes,
    char *error_message, size_t error_capacity
) {
    using Clock = std::chrono::steady_clock;
    if (stage_hashes) {
        std::memset(stage_hashes, 0, sizeof(*stage_hashes));
    }
    std::unique_ptr<FSCRawTherapeeDecoder> raw(
        new FSCRawTherapeeDecoder(full_resolution != 0));
    raw->stageHashes = stage_hashes;
    const auto openStart = Clock::now();
    int code = raw->open_file(path);
    output->open_seconds = std::chrono::duration<double>(Clock::now() - openStart).count();
    if (code != LIBRAW_SUCCESS) {
        std::snprintf(error_message, error_capacity, "%s", libraw_strerror(code));
        return code;
    }
    auto &p = raw->imgdata.params;
    p.output_bps = 16; p.use_camera_wb = 1; p.user_qual = 2;
    p.output_color = 1; p.gamm[0] = 1.0 / 2.4; p.gamm[1] = 12.92;
    const bool isXTrans = raw->imgdata.idata.filters == 9;
    const int previewBound = full_resolution ? 0 : std::max(0, max_dimension);
    p.no_auto_bright = 1; p.highlight = 3;
    p.half_size = (full_resolution || isXTrans || previewBound > 0) ? 0 : 1;
    p.adjust_maximum_thr = 0.75f; p.bright = 1.f; p.exp_correc = 0;
    const auto unpackStart = Clock::now();
    code = raw->unpack();
    output->unpack_seconds = std::chrono::duration<double>(Clock::now() - unpackStart).count();
    if (code == LIBRAW_SUCCESS && stage_hashes) {
        hashUnpackedMosaic(*raw, stage_hashes);
    }
    bool shrunkToPreviewBound = false;
    if (code == LIBRAW_SUCCESS && previewBound > 0) {
        shrunkToPreviewBound = shrinkMosaicToBound(*raw, previewBound);
    }
    if (code == LIBRAW_SUCCESS) {
        const auto processStart = Clock::now();
        const double stageHashSecondsBeforeProcess = raw->stageHashSeconds;
        code = raw->dcraw_process();
        const double processSeconds = std::chrono::duration<double>(
            Clock::now() - processStart).count();
        const double processStageHashSeconds =
            raw->stageHashSeconds - stageHashSecondsBeforeProcess;
        output->demosaic_seconds = raw->demosaicSeconds;
        output->demosaic_workers = raw->xtransWorkerCount;
        output->unpack_workers = raw->unpackWorkerCount;
        output->libraw_postprocess_seconds = std::max(
            0.0,
            processSeconds - output->demosaic_seconds - processStageHashSeconds);
    }
    if (code != LIBRAW_SUCCESS) {
        std::snprintf(error_message, error_capacity, "%s", libraw_strerror(code));
        return code;
    }
    int imageError = LIBRAW_SUCCESS;
    const auto processedImageStart = Clock::now();
    libraw_processed_image_t *processed = raw->dcraw_make_mem_image(&imageError);
    if (imageError != LIBRAW_SUCCESS || !isValidRGB16Bitmap(processed)) {
        if (processed) { libraw_dcraw_clear_mem(processed); }
        std::snprintf(error_message, error_capacity, "LibRaw returned an invalid camera-scan image.");
        return imageError == LIBRAW_SUCCESS ? -1 : imageError;
    }
    if (!full_resolution && isXTrans && previewBound <= 0) {
        libraw_processed_image_t *downsampled = downsampleTwoByTwo(processed);
        if (!downsampled) {
            libraw_dcraw_clear_mem(processed);
            std::snprintf(error_message, error_capacity, "Could not downsample the X-Trans preview.");
            return -1;
        }
        libraw_dcraw_clear_mem(processed);
        processed = downsampled;
    }
    output->processed_image_seconds = std::chrono::duration<double>(
        Clock::now() - processedImageStart).count();
    // Boundary 3: the image LibRaw returns, before the ISO-adaptive filter.
    if (stage_hashes) {
        StageHasher hasher;
        hasher.pod(static_cast<uint32_t>(processed->width));
        hasher.pod(static_cast<uint32_t>(processed->height));
        hasher.pod(static_cast<uint32_t>(processed->colors));
        hasher.bytes(processed->data, rgb16PixelBytes(processed));
        hasher.hexDigest(stage_hashes->processed_image_sha256);
    }
    uint32_t flags = 0;
    if (raw->usedRCD) { flags |= FSC_RAW_PROCESSING_RCD; }
    if (raw->usedXTransThreePass) { flags |= FSC_RAW_PROCESSING_XTRANS_THREE_PASS; }
    if (raw->usedDeterministicParallelXTrans) {
        flags |= FSC_RAW_PROCESSING_XTRANS_DETERMINISTIC_PARALLEL;
    }
    if (raw->usedParallelFujiUnpack) {
        flags |= FSC_RAW_PROCESSING_PARALLEL_FUJI_UNPACK;
    }
    if (shrunkToPreviewBound) {
        flags |= FSC_RAW_PROCESSING_PREVIEW_BOUND;
    }
    const auto isoPolicyStart = Clock::now();
    isoAdaptiveFilter(processed, raw->imgdata.other.iso_speed, flags);
    output->iso_policy_seconds = std::chrono::duration<double>(
        Clock::now() - isoPolicyStart).count();
    // Boundary 4: the same buffer after the ISO-adaptive filter.
    if (stage_hashes) {
        StageHasher hasher;
        hasher.bytes(processed->data, rgb16PixelBytes(processed));
        hasher.hexDigest(stage_hashes->post_iso_sha256);
    }
    output->width = processed->width; output->height = processed->height;
    output->channels = processed->colors;
    output->pixel_count = static_cast<size_t>(processed->width) * processed->height * 3;
    output->bgr_pixels = reinterpret_cast<const uint16_t *>(processed->data);
    output->iso_speed = raw->imgdata.other.iso_speed;
    output->processing_flags = flags;
    std::snprintf(output->color_description, sizeof(output->color_description), "sRGB");
    auto *cleanup = static_cast<Cleanup *>(std::malloc(sizeof(Cleanup)));
    if (!cleanup) {
        libraw_dcraw_clear_mem(processed);
        std::snprintf(error_message, error_capacity, "Could not retain the camera-scan image.");
        return -1;
    }
    cleanup->processed = processed; output->_internal = cleanup;
    return LIBRAW_SUCCESS;
}
