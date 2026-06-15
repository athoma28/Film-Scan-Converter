# Performance Engineering Log

> **Historical legacy-Python log:** This records maintenance work completed
> before the native Swift/macOS application became the primary product. It is
> not the current roadmap. See
> [Native macOS Development](docs/development/native-macos.md).

Started: 2026-06-13 20:36:56 PDT
Branch: `dev`

## Baseline Audit

- Profiled the image processing and GUI display paths.
- Found dust detection running for every process call even when dust removal was disabled.
- Found duplicate final-image conversion during each GUI refresh.
- Found avoidable temporary arrays in contour and histogram rendering.

## Initial Changes

- Skip dust detection when dust removal is disabled.
- Cache dust masks while RAW data, crop geometry, resolution, and dust settings remain unchanged.
- Calculate dust threshold percentiles in one NumPy operation.
- Remove contour sorting that did not affect the rendered dust mask.
- Reuse the converted final image during GUI refresh.
- Reduce temporary arrays in contour and histogram rendering.

## Initial Measurements

Synthetic 6 MP `uint16` image, crop-only processing:

- Default processing path: approximately 2.1x faster.
- Dust detection alone: approximately 39% faster.
- Repeated dust-enabled processing with unchanged mask inputs avoids dust detection.

Pixel-equivalence checks passed for dust masks, histograms, contour zebra overlays, and mask broadcasting.

## Next Work

- Add correctness regression tests and opt-in performance benchmarks.
- Profile complete black-and-white, color-negative, slide, crop-only, display, and export-related paths.
- Apply further behavior-preserving optimizations with equivalence tests and measurements.

## Test Suite

- Added a dependency-light `unittest` correctness suite.
- Added reference implementations to verify exact pixels for:
  - Threshold generation
  - Dust detection
  - Histogram equalization
  - Histogram rendering
  - Exposure adjustment
  - White balance
  - Contour overlays
- Added cache invalidation and multiprocessing serialization tests.
- Added opt-in performance benchmarks using `RUN_PERFORMANCE_TESTS=1`.
- Default suite runtime: approximately 0.15 seconds.

## Further Changes

- Cache histogram statistics while RAW data, resolution, crop geometry, film mode, base settings, black point inputs, and percentile settings remain unchanged.
- Replace two threshold passes plus a bitwise pass with one pixel-equivalent `cv2.inRange` call.
- Reduce full-frame temporary arrays during exposure normalization and final clipping.
- Skip neutral white-balance multiplication and neutral exposure adjustment passes.
- Avoid serializing loaded RAW, proxy, output, mask, and cache arrays into multiprocessing export tasks.
- Lazy-load Matplotlib only when non-default saturation adjustment is used.
- Remove an unused GUI-level RawPy import.

## Current Measurements

Original `main` implementation versus `dev`, representative 2.16 MP `uint16` image, exact output pixels:

| Film mode | Original | Optimized | Speedup |
| --- | ---: | ---: | ---: |
| Black-and-white negative | 0.0601 s | 0.0205 s | 2.93x |
| Color negative | 0.1427 s | 0.0638 s | 2.24x |
| Slide | 0.1472 s | 0.0604 s | 2.44x |
| Crop-only | 0.0203 s | 0.0027 s | 7.44x |

Synthetic 6 MP benchmark:

- Warm color processing after histogram-statistics cache: approximately 0.09-0.10 seconds.
- Neutral exposure pass: approximately 0.014 seconds.
- Batch-export task serialization: 930 bytes while excluding 72,000,000 bytes of reproducible image arrays.

All full-pipeline comparison outputs matched the original implementation exactly.

## Real Scan Verification

Decoded `sample-raw/DSCF2422.RAF` at half resolution to a 2592x3876, 10.0 MP `uint16` image and compared the original and optimized pipelines:

| Film mode | Original | Optimized | Speedup |
| --- | ---: | ---: | ---: |
| Black-and-white negative | 0.3902 s | 0.0977 s | 4.00x |
| Color negative | 1.4025 s | 0.4773 s | 2.94x |
| Slide | 1.2056 s | 0.4342 s | 2.78x |
| Crop-only | 0.1280 s | 0.0405 s | 3.16x |

Every resulting image matched the original pipeline exactly.

Warm processing with cached histogram statistics:

- Black-and-white negative: approximately 0.041 seconds.
- Color negative: approximately 0.174 seconds.
- Slide: approximately 0.169 seconds.

## Representative Five-RAF Corpus

- Classified and benchmarked five user-provided X-T5 RAF scans.
- Recorded film type and correct film-frame rotation in `tests/benchmark_sample_raw.py`.
- Added a repeatable RawPy corpus decoder in `tests/decode_sample_raw.py`.
- Added selected black-and-white and color-negative edit presets.
- Added cold, warm cached, render, and quality-metric reporting.
- Searched 320 constrained edit candidates for each color negative and visually inspected the highest-ranked outputs.
- Replaced adjusted-exposure masked-array arithmetic with pixel-exact NumPy operations.

Detailed findings and measurements are in `SAMPLE_RAW_BENCHMARK_2026-06-13_21-06-32_PDT.md`.

## 2026-06-14 Improvement Proposal Pass

- Evaluated the external suggestions in `docs/improvements/`.
- Recorded implemented, deferred, and high-risk proposals in
  `docs/improvements/EVALUATION.md` for the next model handoff.
- Fixed the lowercase GoPro RAW extension filter.
- Made expected first-run missing-config behavior log at info level.
- Protected background preload tracking with a lock and prevented eviction while loading.
- Lazy-loaded `psutil` and added a conservative export fallback when no memory estimate exists.
- Removed conflicting duplicate OpenCV packages from `source/requirements.txt`.
- Simplified the fixed white-balance dispatch without changing output.
- Added film-mode dispatch and frame/aspect-ratio regression tests.

Verification:

- Full suite: 16 tests passed, 1 opt-in benchmark skipped.
- Opt-in performance suite: passed.
- Python compilation and `git diff --check`: passed.
- Direct GUI import was not runnable in the test interpreter because `rawpy` is not installed.
