#include "../FilmScanEngine/Sources/CLibRawShim/XTransHomogeneity.h"

#include <cassert>
#include <cstdio>
#include <limits>
#include <vector>

template <std::size_t Tile, int Directions>
void verify_map(int mode, int rows, int cols) {
    std::vector<float> source(Directions * Tile * Tile);
    auto derivatives = reinterpret_cast<float (*)[Tile][Tile]>(source.data());
    for (int d = 0; d < Directions; ++d) {
        for (std::size_t row = 0; row < Tile; ++row) {
            for (std::size_t col = 0; col < Tile; ++col) {
                float value = static_cast<float>((row * 13 + col * 29 + d * 7) % 31);
                if (mode == 0) value = 0;
                if (mode == 2) value = std::numeric_limits<float>::quiet_NaN();
                if (mode == 3) value = std::numeric_limits<float>::infinity();
                if (mode == 4) value = -std::numeric_limits<float>::infinity();
                if (mode == 5) value = d == 0 ? FLT_MAX : value;
                if (mode == 6) value = d == 0 ? -FLT_MAX : value;
                if (mode == 7) {
                    if ((row + col + d) % 7 == 0) value = std::numeric_limits<float>::quiet_NaN();
                    else if ((row + col + d) % 7 == 1) value = std::numeric_limits<float>::infinity();
                    else if ((row + col + d) % 7 == 2) value = -std::numeric_limits<float>::infinity();
                    else value -= 15;
                }
                derivatives[d][row][col] = value;
            }
        }
    }
    std::vector<char> actual(Directions * Tile * Tile, 0);
    std::vector<char> expected(actual.size(), 0);
    auto reference = reinterpret_cast<char (*)[Tile][Tile]>(expected.data());
    for (int row = 4; row < rows - 4; ++row) {
        for (int col = 4; col < cols - 4; ++col) {
            float threshold = FLT_MAX;
            for (int d = 0; d < Directions; ++d) {
                if (threshold > derivatives[d][row][col]) threshold = derivatives[d][row][col];
            }
            threshold *= 8;
            for (int d = 0; d < Directions; ++d) {
                for (int v = -1; v <= 1; ++v) {
                    for (int h = -1; h <= 1; ++h) {
                        if (derivatives[d][row + v][col + h] <= threshold) reference[d][row][col]++;
                    }
                }
            }
        }
    }
    // Match the production six-byte-per-pixel Lab capacity with byte canaries.
    constexpr unsigned char canary = 0xA5;
    std::vector<unsigned char> scratch(Tile * Tile * 6 + 32, canary);
    fsc_xtrans_homogeneity<Tile, Directions>(derivatives, scratch.data() + 16,
        reinterpret_cast<char (*)[Tile][Tile]>(actual.data()), rows, cols);
    assert(actual == expected);
    for (int i = 0; i < 16; ++i) {
        assert(scratch[i] == canary);
        assert(scratch[scratch.size() - 1 - i] == canary);
    }
    for (std::size_t i = 16 + Tile * Tile * 4; i < scratch.size() - 16; ++i) {
        assert(scratch[i] == canary);
    }
}

template <std::size_t Tile, int Directions>
void verify_tile() {
    for (int mode = 0; mode < 8; ++mode) {
        verify_map<Tile, Directions>(mode, Tile, Tile);
        verify_map<Tile, Directions>(mode, Tile - 1, Tile - 2);
        verify_map<Tile, Directions>(mode, 8, Tile / 2);
    }
}

int main() {
    verify_tile<9, 4>();
    verify_tile<16, 4>();
    verify_tile<16, 8>();
    verify_tile<512, 8>();
    std::puts("X-Trans homogeneity matches original comparisons and tile bounds.");
}
