# Native RAW Decode And Quality Benchmark

**Date:** 2026-06-16

**Hardware:** Apple M4 Pro, 14 cores, 48 GB memory
**Corpus:** Eight user-provided Fujifilm X-T5 RAF film scans

## Result

The native thread-safe LibRaw decoder produces **byte-for-byte identical**
16-bit BGR buffers to the production RawPy decoder for every sample RAF at both
half and full resolution.

- All dimensions match.
- All SHA-256 pixel hashes match.
- Minimum, maximum, clipping percentages, and per-channel means have zero
  difference.
- PSNR is effectively infinite and perceptual similarity is exact because no
  decoded pixel differs.
- Running the existing selected-edit processing benchmark on these identical
  buffers produces the same downstream images and quality metrics.

## Decode Architecture

The C bridge provides two decode paths in `CLibRawShim.c`:

| Path | Function | I/O | Memory | Notes |
|---|---|---|---|---|
| Direct (current) | `fsc_decode_raw_direct` | mmap + `libraw_open_buffer` | Single copy: LibRaw BGR → Swift `[UInt16]` with in-pass swizzle | Primary path; mmap freed after `libraw_unpack` |
| Legacy | `fsc_decode_raw` | `libraw_open_file` | Double copy: C-side malloc + BGR→RGB swizzle, then Swift `[UInt16]` copy | Kept for caller compatibility |

Both paths produce identical pixel output. The direct path eliminates the
C-side `malloc` + BGR→RGB swizzle loop, reducing the full-resolution decode
from two full-frame copies to one. Debug logging (`FSC_LOG`) is compile-time
gated on `#ifdef DEBUG`; release builds emit no C-side log traffic.

## Embedded JPEG Thumbnail

`RawImageDecoder.extractThumbnail()` extracts the camera-processed JPEG preview
embedded in each RAW file via `libraw_unpack_thumb`. This provides an instant
preview without a full RAW decode:

| File | Resolution | Extraction + decode | vs half-res LibRaw |
|---|---:|---:|---:|
| DSCF0669.RAF | 4416 × 2944 | ~110 ms | ~10× faster |
| DSCF0718.RAF | 4416 × 2944 | ~65 ms | ~16× faster |
| DSCF0729.RAF | 4416 × 2944 | ~67 ms | ~15× faster |

The JPEG is at the camera's native embedded resolution (4416 × 2944 for X-T5),
which is higher than the half-res LibRaw decode (2592 × 3876). `AppModel` shows
the JPEG instantly while a background `authoritativeDecodeTask` uses the serial
decode coordinator to decode the LibRaw buffer
and swaps it in at the same correction settings and proxy dimensions.

## Method

Both decoders use the production processing settings and return owned,
contiguous 16-bit BGR buffers. Timing includes the full decode pipeline:
file I/O, unpack, dcraw processing, memory image creation, and the
Swift-side buffer copy with BGR→RGB conversion.

- RawPy 0.24.0 uses its bundled LibRaw 0.21.3.
- Native Swift uses Homebrew thread-safe LibRaw 0.21.4.
- Half-resolution timing uses the best of five sequential runs.
- Full-resolution timing uses the best of three sequential runs.
- Native timing uses the release-mode `FilmScanRawBenchmark` executable.
- RawPy timing uses `tests/decode_sample_raw.py`.

## Half-Resolution Decode

Each output is `2592 x 3876 x 3`, approximately 60.3 MB.

| File | Native best | Native median |
|---|---:|---:|
| DSCF0669.RAF | 1.000 s | 1.013 s |
| DSCF0718.RAF | 1.005 s | 1.013 s |
| DSCF0729.RAF | 0.996 s | 1.004 s |
| DSCF2417.RAF | 1.002 s | 1.004 s |
| DSCF2422.RAF | 1.016 s | 1.019 s |
| DSCF2433.RAF | 1.012 s | 1.024 s |
| DSCF2437.RAF | 1.026 s | 1.028 s |
| DSCF2440.RAF | 1.029 s | 1.041 s |

Half-resolution performance is effectively equal to RawPy. The LibRaw
`libraw_dcraw_process` dominates decode time (~95%); memory copies and
I/O are negligible at this resolution.

## Full-Resolution Decode

Each output is `5184 x 7752 x 3`, approximately 241.1 MB.

| File | Native best | Native median |
|---|---:|---:|
| DSCF0669.RAF | 7.223 s | 7.249 s |
| DSCF0718.RAF | 7.332 s | 7.381 s |
| DSCF0729.RAF | 7.319 s | 7.375 s |
| DSCF2417.RAF | 7.287 s | 7.297 s |
| DSCF2422.RAF | 7.301 s | 7.349 s |
| DSCF2433.RAF | 7.340 s | 7.355 s |
| DSCF2437.RAF | 7.314 s | 7.359 s |
| DSCF2440.RAF | 7.336 s | 7.385 s |

Full-resolution decode is dominated by `libraw_dcraw_process` (demosaicing via
PPG interpolation, color space conversion, gamma, brightness). The direct decode
path eliminates the C-side `malloc` + BGR→RGB swizzle copy previously noted as
a 19.7% overhead source; current measurements show no measurable overhead from
the bridge layer. Further full-res improvements require LibRaw-level changes
(e.g. GPU-accelerated demosaicing) or architectural changes (e.g. using the
embedded JPEG for preview and deferring full-res decode to export time).

## Selected-Edit Quality

The existing selected-edit benchmark was rerun on the exact decoded proxy
buffers. These metrics therefore apply equally to RawPy and native decode.

| File / selected edit | Entropy | Black clip | White clip | Median RGB |
|---|---:|---:|---:|---:|
| DSCF0669 tonal recovery | 6.199 bits | 0.448% | 0.521% | grayscale 50 |
| DSCF0718 tuned cooler | 7.669 bits | 0.726% | 0.003% | 154 / 163 / 155 |
| DSCF0729 tuned | 7.801 bits | 0.344% | 0.174% | 93 / 85 / 92 |
| DSCF2417 contrast | 7.552 bits | 0.000% | 0.170% | grayscale 139 |
| DSCF2422 tuned | 7.665 bits | 1.562% | 0.398% | 94 / 87 / 91 |

Across all 23 edit variants, best cold processing totaled **17.22 seconds** and
best warm cached processing totaled **10.52 seconds**. These are historical
legacy-Python selected-edit baselines. The native engine now contains several
correction stages and a complete TIFF/JPEG/PNG/DNG export path. A direct
full-pipeline comparison including crop, perspective, and dust stages still
requires the remaining legacy replacement gates.

## Reproduce

```sh
swift build -c release \
  --package-path native/FilmScanEngine \
  --product FilmScanRawBenchmark

# Half-resolution (5 repetitions)
native/FilmScanEngine/.build/release/FilmScanRawBenchmark \
  sample-raw /tmp/film_scan_native_half.json 5

# Full-resolution (3 repetitions)
native/FilmScanEngine/.build/release/FilmScanRawBenchmark \
  sample-raw /tmp/film_scan_native_full.json 3 --full-resolution

# RawPy baseline for comparison (requires .venv with rawpy)
.venv/bin/python tests/decode_sample_raw.py \
  --raw-dir sample-raw \
  --output-dir /tmp/film_scan_rawpy_half \
  --repetitions 3

.venv/bin/python tests/compare_raw_decode_benchmarks.py \
  --rawpy /tmp/film_scan_rawpy_half/decode_results.json \
  --native /tmp/film_scan_native_half.json \
  --output /tmp/film_scan_compare_half.json
```
