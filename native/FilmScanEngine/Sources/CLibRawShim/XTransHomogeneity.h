#ifndef FSC_XTRANS_HOMOGENEITY_H
#define FSC_XTRANS_HOMOGENEITY_H

#include <cfloat>
#include <cstddef>
#include <cstring>

// Finish every direction's derivatives before calling. The threshold map uses
// the dead Lab plane through byte copies, preserving its C++ object lifetimes.
// All three ranges are disjoint. Output borders/padding must already be zero.
template <std::size_t Tile, int Directions>
inline void fsc_xtrans_homogeneity(
    const float (*__restrict derivatives)[Tile][Tile],
    void *labStorage,
    char (*__restrict homogeneity)[Tile][Tile],
    int rows,
    int cols
) {
    auto *__restrict thresholds = static_cast<unsigned char *>(labStorage);
    for (int row = 4; row < rows - 4; ++row) {
        for (int col = 4; col < cols - 4; ++col) {
            float threshold = FLT_MAX;
            // Preserve the original comparison order, including NaN and Inf.
            for (int direction = 0; direction < Directions; ++direction) {
                if (threshold > derivatives[direction][row][col]) {
                    threshold = derivatives[direction][row][col];
                }
            }
            threshold *= 8;
            std::memcpy(thresholds + (row * Tile + col) * sizeof(float),
                &threshold, sizeof(threshold));
        }
    }
    // Contiguous columns in one direction expose independent comparisons to
    // the optimizer. Integer counts and the nine comparisons stay exact.
    for (int direction = 0; direction < Directions; ++direction) {
        const auto *__restrict plane = derivatives[direction];
        auto *__restrict output = homogeneity[direction];
        for (int row = 4; row < rows - 4; ++row) {
            for (int col = 4; col < cols - 4; ++col) {
                float threshold;
                std::memcpy(&threshold,
                    thresholds + (row * Tile + col) * sizeof(float), sizeof(threshold));
                int count = 0;
                for (int v = -1; v <= 1; ++v) {
                    for (int h = -1; h <= 1; ++h) {
                        count += plane[row + v][col + h] <= threshold;
                    }
                }
                output[row][col] = static_cast<char>(count);
            }
        }
    }
}

#endif
