# CPU Preview Diagnostics and Darkroom Analysis

The initial measurements below are from September 4. A
[September 8 follow-up](#darkroom-percentile-reuse) removes repeated
sorting from textured Darkroom analysis with a fresh same-session baseline.

Measured on 2026-09-04 on an Apple M4 Pro, Mac16,7, 48 GB RAM,
14 CPU cores (10 performance, 4 efficiency), running macOS 15.7.9 and
Swift 6.1.2 in release mode.
The baseline is `42c194325417527a67521457f12e101534a703de` with existing
uncommitted documentation and viewer-test changes. The benchmark harness and
an internal test access change were added before measuring; processing code
was otherwise unchanged. The candidate adds the two repairs below. Existing
uncommitted work was preserved.

## Measurements

| Isolated stage | Before p50 / p95 | After p50 / p95 | Process peak before → after |
|---|---:|---:|---:|
| 40.19 MP RGB preview diagnostics | 147.16 / 151.31 ms | 7.08 / 8.19 ms | 1,217.3 → 249.9 MB |
| 40.19 MP grayscale preview diagnostics | 97.82 / 100.80 ms | 6.72 / 6.93 ms | 1,057.8 → 87.2 MB |
| Darkroom analysis, flat input | 450.67 / 464.77 ms | 5.54 / 5.61 ms | 34.8 → 13.6 MB |
| Darkroom analysis, textured input | 73.44 / 75.16 ms | 73.79 / 76.36 ms | 24.5 → 20.3 MB |

RGB diagnostics were 20.8× faster in this run, with about 967 MB less peak
physical footprint. The flat-input Darkroom case was 81.3× faster. Textured
Darkroom timing was effectively unchanged; sorting and other analysis work
still dominate that input. Memory units above are decimal MB and include the
input image and test process. See the [raw samples](preview-analysis-2026-09-04.json).

## Changes

CPU preview diagnostics previously converted every pixel to three-channel
`Double` storage before collecting at most 65,536 samples. At 7728 × 5200,
that temporary array alone occupied 964,454,400 bytes, even for grayscale
images. `UInt16Image.previewStatistics()` now converts only the selected
pixels, using the same sampler as `RenderReadyLinearImage.statistics()`.
Sampling positions, total pixel counts, percentile interpolation, clipping
rules, and normalized display-code values are unchanged. Statistics storage
is bounded independently of image dimensions.

Darkroom's `samePixelColorFloors` previously selected pixel indices and then
searched the original band again for every selected pixel's chroma. Tied
samples in a flat image made this search quadratic. The selector now retains
each index and its chroma together in one pass, preserving selection order,
ties, thresholds, and both neutral-axis passes. This analysis is shared by
the CPU and GPU Darkroom paths.

## Reproduction

Build the release test bundle once:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/fsc-performance-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/fsc-performance-swift-cache \
swift test --disable-sandbox -c release \
  --package-path native/FilmScanEngine --no-parallel \
  --filter PreviewAnalysisTests
```

Run each benchmark case in its own process for a meaningful process-lifetime
memory peak. Cases are `statistics-40mp-3ch`, `statistics-40mp-1ch`,
`darkroom-textured`, and `darkroom-flat`:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/fsc-performance-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/fsc-performance-swift-cache \
RUN_PREVIEW_ANALYSIS_BENCHMARKS=1 \
PREVIEW_ANALYSIS_CASE=statistics-40mp-3ch \
swift test --disable-sandbox --skip-build -c release \
  --package-path native/FilmScanEngine --no-parallel \
  --filter PreviewAnalysisPerformanceTests
```

The harness performs one warm-up and five timed repetitions, checks every
result against the warm-up, and prints a JSON record with all samples, median,
nearest-rank p95, and Mach current/peak physical footprint. Input construction
is outside the timer but is included in process memory. Inputs are deterministic:
7728 × 5200 UInt16 images for diagnostics; 1000 × 667 images for Darkroom,
using Phoenix II and Crystal Archive. The flat case contains code value 30,000
in every channel. The textured case uses a fixed pseudo-random sequence.

These isolate analysis stages. They do not measure overall slider latency,
RAW decode, or export speed. Normal GPU preview statistics already use a
bounded proxy; the large allocation repair affects CPU fallback previews,
including geometry edits. The flat Darkroom input is a stress case for ties,
not a representative speedup for every photograph.

## Equivalence

`PreviewAnalysisTests` compares RGB and grayscale diagnostics against full-frame
normalization around the sampling limit, with single-sample, custom, and
oversized sample requests. It also pins nine pre-change SHA-256 references
covering the complete Darkroom analysis and rendered UInt16 pixels: flat,
quantized, and textured input, each on Neutral, Crystal Archive, and Endura.
No existing pixel reference was refreshed.

Validation on the candidate:

- Full native release suite: **547 tests passed** in 228.44 seconds, with ten
  opt-in benchmarks/workflow tests skipped by default. This included GPU
  density-print parity, app preview/geometry integration, available RAW corpus
  regressions, and all nine new reference hashes. The suite ran with macOS
  graphics services available.
- The four isolated benchmark cases were enabled and run separately using
  the commands above.
- Strict recursive Swift formatting lint and `git diff --check` passed.

The full-suite command, after building the release tests, was:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/fsc-performance-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/fsc-performance-swift-cache \
swift test --disable-sandbox --skip-build -c release \
  --package-path native/FilmScanEngine --no-parallel
```

<a id="darkroom-percentile-reuse"></a>

## Darkroom Percentile Reuse — 2026-09-08

The remaining textured-input cost included sorting the same log-channel samples
for every percentile query. `LogChannelStatistics` now sorts each channel once
and computes both pairs of bounds and the shadow reference from that ordering.
With cast removal enabled this reduces fifteen whole-channel sorts to three.
Only the scalar results survive the initializer; neutral-axis processing still
uses the original pixel order. Textural range and the same-pixel luminance band
also each share one sort between their two percentile queries.

The percentile interpolation, sampling, clipping, BGR layout, and two-pass
neutral-axis selection are unchanged. This analysis supplies both CPU rendering
and GPU uniforms. The change does not alter the RAW decoder or render kernels.

### Same-Session Release Measurements

| Isolated stage | Before p50 / p95 | After p50 / p95 | Process peak before → after |
|---|---:|---:|---:|
| Darkroom analysis, textured input | 103.34 / 103.56 ms | 43.83 / 44.38 ms | 13.84 → 16.76 MB |
| Darkroom analysis, flat input | 7.37 / 7.93 ms | 5.14 / 5.21 ms | 15.78 → 14.48 MB |

Textured analysis was 2.36× faster (57.6% less time) and flat analysis was 1.44×
faster in this run. The textured process peak increased by 2.92 MB; sorting all
three sampled channels together trades a small, bounded amount of temporary
storage for fewer sorts. These process-wide peaks include the test runtime and
input image and are not per-stage allocation counts. MB is decimal.

Hardware was Apple M4 Pro / Mac16,7, 48 GiB RAM, 14 CPU cores, macOS 15.7.9
(24G830), Swift 6.1.2. Baseline was `42c1943` plus all pre-existing working-tree
changes, including the September 4 analysis repairs. Candidate adds the sort
reuse and focused tests. The [raw report](darkroom-sort-reuse-2026-09-08.json)
contains every timed sample, initial `git status --short`, and SHA-256 for the
baseline and candidate processing source.

The harness and inputs are unchanged: one warm-up and five repetitions per
case, 1000 × 667 deterministic BGR images, Phoenix II / Crystal Archive, 20%
inset. Each case ran sequentially in a separate process under the same tool
sandbox. Use the build and opt-in commands above with `darkroom-textured` or
`darkroom-flat`. Compare each September 8 candidate to its same-session baseline,
not to September 4 timings. These isolate analysis work and do not establish an
end-to-end slider or export speedup.

### Equivalence And Validation

The existing nine pre-change analysis-plus-UInt16 SHA-256 references all pass;
none was refreshed. New `DensityPrintStatisticsTests` compares all five BGR
percentiles with independent full-sort queries for empty, single, paired, small,
and 65,536-sample inputs, including ties and distinct channel ranges. It also
checks exact interpolation, endpoint clamping, and empty-input behavior.

- Full native release suite passed in 293.06 seconds: **580 tests reported,
  570 passing test records and 10 explicitly skipped opt-in tests**. It ran
  with macOS graphics access and included Darkroom CPU/GPU parity, RAW
  stage/output references, available corpus checks, and app/geometry tests.
- All five focused release tests passed. Run them after building with
  `--filter 'PreviewAnalysisTests|DensityPrintStatisticsTests'`.
- Both benchmark cases passed separately with their opt-in flag enabled.
- Strict recursive Swift formatting lint and `git diff --check` passed.
