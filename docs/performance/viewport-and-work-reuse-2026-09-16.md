# Viewport rendering and work reuse

September 16, 2026. Follow-up to the September 14 interaction-preview work.

## Changes

- Navigation reuses the inspect/detail session decoded before the selected full
  preview. It no longer resizes the previous sensor image or repacks its renderer
  on the main actor. The retained fallback counts against the 256 MiB background
  budget. Under pressure, background sessions are evicted instead of resized on
  the UI thread. A full session without a prior smaller tier is evicted on exit.
- A selected-source CPU preparation owner caches exact geometry and Darkroom
  analysis. Geometry edits invalidate both; resolved profile/paper changes
  invalidate analysis. Point controls reuse them. Source/flat-field generations
  replace the owner. Sensor-space measured-density processing keeps its reference
  path. At most one transformed source is retained by each active owner.
- RAW preview, neighbour, stack, and final RAW export decoding share one priority
  scheduler. Selected work interrupts speculative neighbours. Caller cancellation
  reaches an atomic native token; LibRaw progress callbacks, Fuji strip boundaries,
  CFA shrink rows, and X-Trans wavefront boundaries observe it. Queued cancelled
  work does not decode. Gesture editing pauses preview upgrades/lookahead and
  resumes them after release. An active native operation still stops at a safe
  boundary rather than freeing storage from underneath workers.
- Fit rendering scales the corrected Core Image graph to the viewport's backing
  resolution. Inspection renders a full-source visible region plus overscan, with
  a small whole-document overview beneath it during panning. Logical canvas size
  and editing overlays remain unchanged. Correction occurs before output scaling;
  source/profile analysis remains independent of pan/zoom. Headless callers without
  viewport demand retain the full-raster API and existing reference tests.
- Semantic color/tone processing uses bounded row bands, including power-law
  processing with medians resolved once over the complete geometrically prepared
  image. The target band is 131,072 pixels (one row minimum). One three-channel
  Double band is approximately 3 MiB versus 920 MiB for one 7752 × 5184 Double
  frame. This is payload arithmetic, not a process-footprint measurement. Input,
  output, geometry, band copies, and framework allocations remain additional.
- Core Image raster creation explicitly disables deferred rendering, so GPU
  correction completes in the render worker before AppKit receives the image.
  Statistics run after publication in a queue with one active and one newest
  pending request. Continuous gestures submit at most ten diagnostic updates per
  second and release requests a final update. Results carry their render/source
  revision and cannot overwrite a newer frame's diagnostics. CPU samples preserve
  the exact original sample positions without retaining a full corrected image.

The existing 2048px interaction proxy remains useful for whole-image gestures.
Inspection uses the full source for its visible region. CPU-only geometry/density
cases retain exact full-source correction; the preparation cache reduces their
repeated work. Export remains UInt16 with the established operation order and
quantization boundaries. This change does not adopt the preview tolerance for
export, introduce a new demosaic algorithm, or replace AppKit raster presentation
with an MTKView.

## Validation

The release build passes. The complete release suite reported **639 tests passed**
in 318.915 seconds, with 14 optional workload tests skipped and no failures. After
the final integer-region rounding/backing-scale fix and additional queue tests,
**25 focused tests passed** in 12.039 seconds (one opt-in replay skipped). Strict
Swift formatting and `git diff --check` pass for this change.

Checks include exact banded-versus-whole-frame color and power-law output, cached
geometry/Darkroom parity and invalidation, unchanged CPU diagnostic sample ranks,
native cancellation/recovery, queued cancellation and export priority, scheduled
versus direct final-quality RAW stage hashes, viewport geometry, full-raster versus
visible-region pixels, and final asynchronous statistics revision. The full suite
also covers the existing RAW references, export, Original comparison, and navigation.

## Bounded measurements

The [raw timing samples](work-reuse-measurements-2026-09-16.json) were collected in
an isolated release process on arm64 macOS 15.7.9 (24G830), Swift 6.1.2, with a
working tree based on `4e962c1`. Each case has three alternating samples. GPU cases
have one warm-up and an identical bitmap/statistics consumer to force comparable
work; the visible-region case also consumes its 1024px overview.

| Workload | Reference median | New median | Observation |
|---|---:|---:|---|
| 7752 × 5184 corrected RAW, Fit at 2048px | 94.02 ms whole raster | 26.38 ms | 3.56× faster |
| Same RAW, 20% width/height inspection region plus overview | 94.02 ms whole raster | 35.10 ms | 2.68× faster |
| 2 MP CPU Darkroom + straighten + tone/color edits | 201.56 ms recomputing preparation | 173.28 ms cached | 14.0% less time |
| 2 MP semantic color/tone seam | 44.67 ms whole-frame Double buffer | 47.18 ms banded | Memory reduction; no observed speedup in this small case |

These compare exact full-source rendering against whole-raster rendering. They
do not claim to improve on the existing temporary 2048px input proxy's gesture
latency. Banding is retained for its bounded scratch memory; the small CPU timing
was about 5.6% slower by median and has appreciable sample variation. The three
samples are not a population-tail estimate. Neither native input, screen
presentation, battery use, nor the banding process-footprint delta was measured.

A separate small alternating-stripe B&W probe compared the scaled corrected graph
with scaling an already rendered full raster. Maximum difference was one 8-bit
code value, consistent with the extra intermediate RGBA8 quantization; it is a
bounded resampling check rather than photographic acceptance of every zoom level.

Reproduce the focused checks and isolated timing probe from the repository root
with normal macOS graphics access and the local RAF corpus:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/fsc-work-reuse-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/fsc-work-reuse-swift \
swift test --disable-sandbox -c release --package-path native/FilmScanEngine \
  --jobs 2 --no-parallel \
  --filter 'CPUPreparationPerformanceTests|RawDecodeSchedulerTests|ViewportRenderingTests|PreviewPublicationTests|PreviewViewportTests'

RUN_WORK_REUSE_BENCHMARK=1 \
WORK_REUSE_BENCHMARK_OUTPUT=/tmp/fsc-work-reuse.json \
swift test --skip-build -c release --package-path native/FilmScanEngine \
  --no-parallel --filter PerformanceFollowupBenchmarks
```

## RAW determinism

The five-repetition parallel run on `fuji400-fresh/DSCF2833.RAF` agrees at all
eight boundaries and preserves the established LZW TIFF hash
`7be6f460d7d47e46a41f1196c88dc4bce00a22c14583c0f64e5fdd7f6311007a`.
Five additional repetitions with `FSC_UNPACK_WORKERS=1 FSC_XTRANS_WORKERS=1`
match all eight boundaries of the eight-worker run. The established TIFF hash is
unchanged across all ten outputs. Every output was removed after hashing. The
[combined raw report](raw-work-reuse-determinism-2026-09-16.json) retains all samples,
worker counts, physical-footprint readings, cleanup flags, and boundary agreement.
These diagnostic LZW runs include hashing and are not default TIFF latency claims.

```sh
native/FilmScanEngine/.build/release/FilmScanExportBenchmark \
  sample-raw /tmp/fsc-parallel.json 5 --determinism \
  --file=fuji400-fresh/DSCF2833.RAF
FSC_UNPACK_WORKERS=1 FSC_XTRANS_WORKERS=1 \
native/FilmScanEngine/.build/release/FilmScanExportBenchmark \
  sample-raw /tmp/fsc-serial.json 5 --determinism \
  --file=fuji400-fresh/DSCF2833.RAF
```
