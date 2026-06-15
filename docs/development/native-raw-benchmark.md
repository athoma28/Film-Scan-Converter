# Native RAW Decode And Quality Benchmark

**Date:** 2026-06-14

**Hardware:** Apple M4 Pro, 14 cores, 48 GB memory
**Corpus:** Five user-provided Fujifilm X-T5 RAF film scans

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

## Method

Both decoders use the production processing settings and return owned,
contiguous 16-bit BGR buffers. Timing includes RGB-to-BGR conversion and the
owned output copy.

- RawPy 0.24.0 uses its bundled LibRaw 0.21.3.
- Native Swift uses Homebrew thread-safe LibRaw 0.21.4.
- Half-resolution timing uses the best of three sequential runs.
- Full-resolution timing uses one sequential run because each output is
  approximately 241 MB.
- Native timing uses the release-mode `FilmScanRawBenchmark` executable.
- RawPy timing uses `tests/decode_sample_raw.py`.

The first benchmark implementation incorrectly discarded whole seconds from
native `Duration` values. The results below are from the corrected runner.

## Half-Resolution Decode

Each output is `2592 x 3876 x 3`, approximately 60.3 MB.

| File | RawPy | Native | RawPy / native | Exact pixels |
|---|---:|---:|---:|---|
| DSCF0669.RAF | 1.504 s | 1.535 s | 0.98x | Yes |
| DSCF0718.RAF | 1.542 s | 1.536 s | 1.00x | Yes |
| DSCF0729.RAF | 1.525 s | 1.489 s | 1.02x | Yes |
| DSCF2417.RAF | 1.501 s | 1.489 s | 1.01x | Yes |
| DSCF2422.RAF | 1.540 s | 1.501 s | 1.03x | Yes |

Geometric-mean RawPy/native ratio: **1.008x**. Half-resolution performance is
effectively equal.

## Full-Resolution Decode

Each output is `5184 x 7752 x 3`, approximately 241.1 MB.

| File | RawPy | Native | RawPy / native | Exact pixels |
|---|---:|---:|---:|---|
| DSCF0669.RAF | 9.257 s | 10.949 s | 0.85x | Yes |
| DSCF0718.RAF | 9.266 s | 11.107 s | 0.83x | Yes |
| DSCF0729.RAF | 9.205 s | 11.031 s | 0.83x | Yes |
| DSCF2417.RAF | 9.274 s | 10.927 s | 0.85x | Yes |
| DSCF2422.RAF | 9.112 s | 11.180 s | 0.82x | Yes |

Geometric-mean RawPy/native ratio: **0.835x**. The current native path is about
**19.7% slower** at full resolution. The likely cost is the bridge's required
owned BGR allocation followed by a second copy into Swift's `[UInt16]`.
Eliminating one full-frame copy is the next decode-performance opportunity, but
must retain exact pixels and memory ownership safety.

## Selected-Edit Quality

The existing selected-edit benchmark was rerun on the exact decoded proxy
buffers. These metrics therefore apply equally to RawPy and native decode.

| File / selected edit | Entropy | Black clip | White clip | Median RGB |
|---|---:|---:|---:|---|
| DSCF0669 tonal recovery | 6.199 bits | 0.448% | 0.521% | grayscale 50 |
| DSCF0718 tuned cooler | 7.669 bits | 0.726% | 0.003% | 154 / 163 / 155 |
| DSCF0729 tuned | 7.801 bits | 0.344% | 0.174% | 93 / 85 / 92 |
| DSCF2417 contrast | 7.552 bits | 0.000% | 0.170% | grayscale 139 |
| DSCF2422 tuned | 7.665 bits | 1.562% | 0.398% | 94 / 87 / 91 |

Across all 23 edit variants, best cold processing totaled **17.22 seconds** and
best warm cached processing totaled **10.52 seconds**. These are historical
legacy-Python selected-edit baselines. The native engine now contains several
correction stages, but does not yet have the complete end-to-end processing and
export workflow required for a direct full-pipeline comparison.

## Reproduce

```sh
swift build -c release \
  --package-path native/FilmScanEngine \
  --product FilmScanRawBenchmark

.venv/bin/python tests/decode_sample_raw.py \
  --raw-dir sample-raw \
  --output-dir /tmp/film_scan_rawpy_half \
  --repetitions 3

native/FilmScanEngine/.build/release/FilmScanRawBenchmark \
  sample-raw /tmp/film_scan_native_half.json 3

.venv/bin/python tests/compare_raw_decode_benchmarks.py \
  --rawpy /tmp/film_scan_rawpy_half/decode_results.json \
  --native /tmp/film_scan_native_half.json \
  --output /tmp/film_scan_compare_half.json
```
