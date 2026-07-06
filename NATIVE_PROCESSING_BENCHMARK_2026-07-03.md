# Native Processing Benchmark — Optimized

Initial run: 2026-07-03  
Corrected-matrix rerun: 2026-07-05  
Branch: `dev`  
Hardware: Apple M4 Pro, 14 cores, 48 GB memory

Native Swift `FilmScanProcessingBenchmark` measuring the complete
decode + processing pipeline (no Python/RawPy involved).

## What Changed Since Legacy Python Benchmark

The old `SAMPLE_RAW_BENCHMARK_2026-06-13` measured a Python/NumPy pipeline.
This benchmark measures the native Swift pipeline:

| | Python (June 13) | Native (baseline) | Native (corrected optimized) |
| --- | ---: | ---: | ---: |
| Decoder | RawPy 0.24.0 | LibRaw 0.21.4 (C bridge) | Same |
| Processing | NumPy masks | Swift Double hot loop | Float LUT + Double pow |
| 15-edit cold total | ~7.0s (est.) | 29.70s | 16.37s |

## Optimization Applied

### Float LUT for sRGB → Linear Conversion

One 65,536-entry Float lookup table replaces `pow()` calls in `sRGBToLinear()`
inside every film negative inversion pass. The exact Rec.2020 matrix is applied
after the three channel lookups, so off-diagonal contributions are not scaled
twice. Median calibration continues to use the scalar `computeMultipliers`
contract shared with the GPU renderer.

Double `pow()` is retained for the per-channel power-law exponent step to
preserve 16-bit precision. The Float LUT reduces error by computing from
Double inputs and rounding once.

### Fused Power-Law Inversion Path

A new `applyFusedPowerLawInversion()` function combines forward inversion
(UInt16 → linear Rec.2020 → power-law) and display rendering (Rec.2020 → sRGB
→ film tone curve) into a single pass, eliminating the 240 MB intermediate
`RenderReadyLinearImage` allocation. Used when no additional tone or colour
adjustments are active (the majority of previews).

Both `applyPowerLawInversion` (legacy) and `powerLawRenderReadyLinear` +
`renderPowerLawDisplay` (linear seam) share the same Float linearization LUT.

## Results: 10 MP Processing (2592 × 3876)

Best of 3 cold processing runs; decode is measured separately below:

| File / edit | Baseline | Corrected optimized | Speedup |
| --- | ---: | ---: | ---: |
| DSCF0669 neutral | 2.051 s | 1.173 s | 1.7× |
| DSCF0669 tonal recovery | 1.982 s | 1.084 s | 1.8× |
| DSCF0669 contrast | 1.987 s | 1.084 s | 1.8× |
| DSCF0718 film base only | 1.941 s | 1.098 s | 1.8× |
| DSCF0718 tuned | 2.028 s | 1.101 s | 1.8× |
| DSCF0718 tuned cooler | 1.854 s | 0.973 s | 1.9× |
| DSCF0729 film base only | 1.945 s | 1.111 s | 1.8× |
| DSCF0729 tuned | 2.054 s | 1.111 s | 1.8× |
| DSCF0729 tuned cooler | 2.058 s | 1.117 s | 1.8× |
| DSCF2417 neutral | 1.925 s | 1.089 s | 1.8× |
| DSCF2417 tonal recovery | 1.852 s | 0.974 s | 1.9× |
| DSCF2417 contrast | 1.853 s | 0.980 s | 1.9× |
| DSCF2422 film base only | 1.985 s | 1.160 s | 1.7× |
| DSCF2422 tuned | 2.090 s | 1.160 s | 1.8× |
| DSCF2422 tuned cooler | 2.091 s | 1.151 s | 1.8× |

**15-edit cold total:** 29.70 s → 16.37 s (1.8× faster)  
**Per-edit mean:** 1.98 s → 1.09 s  
**Best single edit:** 0.97 s (DSCF0718 tuned cooler)

## Quality

Follow-up verification on 2026-07-05 corrected an initial implementation that
scaled off-diagonal Rec.2020 contributions twice. The complete 312-test native
suite now passes. The production GPU parameter-grid and tone-control comparisons
again pass their existing maximum tolerance of 2/255. The LUT remains a
linearization optimization only; matrix and median-calibration semantics match
the scalar/GPU contract.

Entropy and per-channel medians remain within the same visual quality band
as the Double pipeline.

## Decode

| File | Best | Median |
| --- | ---: | ---: |
| DSCF0669.RAF | 1.066 s | 1.075 s |
| DSCF0718.RAF | 1.066 s | 1.069 s |
| DSCF0729.RAF | 1.058 s | 1.061 s |
| DSCF2417.RAF | 1.054 s | 1.069 s |
| DSCF2422.RAF | 1.072 s | 1.075 s |

Half-resolution libraw_dcraw_process dominate at ~95% of decode time. No
processing-level optimization can improve this without GPU-accelerated
demosaicing or architectural changes (deferred full-res decode).

## Reproduce

```sh
swift build -c release \
  --package-path native/FilmScanEngine \
  --product FilmScanProcessingBenchmark

native/FilmScanEngine/.build/release/FilmScanProcessingBenchmark \
  sample-raw /tmp/film_scan_native_proc.json 3
```
