# Native macOS Development

This page is the authoritative status for the Swift/macOS rewrite. It describes
what works now, the current development step, and the order of upcoming work.
The detailed [macOS native roadmap](../improvements/MacOS-Native-Roadmap.md) is
the design reference, not a statement that every listed item is implemented.

**Last updated:** 2026-06-14

Last modified: 2026-06-14 (curves and color wheels: authoritative engine, GPU preview kernel, 35 tests, 95 total)

## Goal

Build a native Swift and SwiftUI version of Film Scan Converter that:

- produces pixel-equivalent final exports from the same RAW inputs and settings;
- improves preview and batch-processing performance;
- provides a modern macOS interface without removing the existing Python app
  before the native replacement is ready;
- provides a low-latency corrected camera preview when the DSLR or capture
  adapter exposes a video feed to macOS.

## Current Development Step

**Active step: authoritative RGB curves and three-way color wheels — complete.** Curves and color wheels are implemented in the authoritative engine, with a matching GPU preview kernel using a 256×256 LUT texture and per-pixel tonal masks. Both are tested.

Export (TIFF/JPEG/PNG/DNG) is the next priority.

## Next Step

**Implement TIFF/JPEG/PNG/DNG export with individual and memory-bounded batch workflows.**

The export stage must preserve orientation, dimensions, bit depth, color profile, source metadata, and processing metadata. DNG scope is processed, demosaiced 16-bit RGB with explicit color/profile metadata. Must include round-trip, cancellation, partial-file cleanup, and reproducible output tests.

## Progress

| Area | Status | Current result |
|---|---|---|
| Phase 0: regression gate | In progress | Swift tests consume frozen Python-generated `.npy` fixtures and compact RAW hash manifests. Standard decode fixtures cover 8-bit PNG, grayscale PNG, BMP, JPEG, and 16-bit TIFF. Five half-size RAF decodes and one full-resolution RAF decode require exact SHA-256 equality with RawPy when the local `sample-raw` corpus is present. The full intermediate-stage and parameter-grid corpus is not complete. |
| Phase 1: processing engine | In progress | `FilmScanEngine` decodes standard images and RAW files, with pixel-equivalent rotate, flip, frame, and aspect-ratio helpers. Threshold generation, white balance, saturation, exposure, histogram equalisation, `shrink_box` coordinate math, overall/per-channel RGB curves (piecewise-linear 65536-entry LUTs), and highlight/midtone/shadow color wheels (tonal masks with luminance preservation) are complete with exact or documented-tolerance equivalence. Contour detection, perspective warp, and dust detection are deferred. |
| Phase 2: accelerated rendering | In progress | Live camera preview uses a Metal-backed Core Image context. Still-file correction uploads one bounded 16-bit proxy per selection, applies the current correction controls in one custom GPU color kernel, and keeps only one in-flight render plus the newest pending snapshot. The kernel now includes curve LUT sampling (256×256 8-bit texture) and three-way color wheel tonal adjustments. GPU-vs-CPU algorithmic equivalence is verified across 696 parameter combinations (≤64 8-bit-level max difference). Render instrumentation (os_signpost + latency counters) is deployed. Display-rate coalescing caps renders at ~60 Hz with p95 GPU kernel+CGImage latency at 2.89 ms across 500 parameter changes (1080×720 proxy, well under the 33 ms gate). Scheduling contract tests verify coalescing, latest-value-wins, and bounded backlog. A Metal-backed preview surface and idle authoritative rendering remain. |
| Phase 3: SwiftUI application | Correction prototype | The app accepts supported files by drag and drop, decodes standard images and RAW files, and provides per-file film mode, orientation, white balance, exposure, shadows, highlights, saturation, reset, and original/corrected comparison controls. Slider bindings now remain live during continuous drags; end-to-end latency still requires real-file verification. |
| Phase 4: performance and polish | Early measurement | CI builds and tests the current native package. The representative RAW decode and quality benchmark is complete; packaging, UI snapshots, and release work remain. |

## Planned Native Capabilities

Export is now the next implementation priority:

- TIFF, JPEG, PNG, and DNG export, including individual and memory-bounded batch
  workflows;
- an initial DNG contract for processed, demosaiced 16-bit RGB output with
  explicit metadata, not reconstruction of the original camera sensor mosaic.

Curves and color wheels are complete:
- an overall tone curve plus independent red, green, and blue channel curves
  (piecewise-linear interpolation, 65536-entry 16-bit CPU LUTs, 256×256 8-bit
  GPU LUT texture);
- highlight, midtone, and shadow color wheels backed by smoothstep tonal masks
  with luminance preservation.

## Implemented Native Features

- A buildable Swift Package Manager library and macOS SwiftUI executable.
- Main-window drag and drop for supported RAW and image file extensions.
- File admission deduplication and case-insensitive extension handling.
- ImageIO/Core Graphics decoding of PNG, JPEG, BMP, and TIFF files into native
  16-bit engine buffers.
- Python-equivalent BGR channel ordering and 8-bit-to-16-bit scaling for the
  committed standard-image fixtures. PNG, BMP, and TIFF fixtures require exact
  equality; the JPEG fixture permits a maximum difference of 10 and a mean
  difference of 2 on the original 8-bit scale because ImageIO and OpenCV use
  different lossy JPEG decoders.
- Preview generation from decoded `UInt16Image` buffers.
- Background standard-image decoding so full-resolution imports do not block
  the SwiftUI main actor.
- A narrow C module boundary around thread-safe LibRaw, returning owned 16-bit
  BGR buffers with no LibRaw lifetime exposed to Swift.
- Exact RawPy-equivalent half-size decoding for all five representative X-T5
  RAF files and exact full-resolution decoding for one representative RAF.
- A reproducible [native RAW decode and quality benchmark](native-raw-benchmark.md)
  proving exact decoded pixels for all five RAFs at half and full resolution.
- Background RAW decoding and preview through the same engine-buffer path used
  by standard images.
- A bounded 1080-pixel correction preview proxy that rerenders verified engine
  corrections in the background without changing the full decoded source. This
  CPU path is currently suitable only as an idle correctness preview, not
  continuous real-time interaction.
- A reusable Core Image/Metal still-preview renderer that uploads one bounded
  16-bit proxy per selection, disables implicit working-space conversion, and
  fuses inversion, grayscale, white balance, tone, and HSV saturation into one
  GPU color kernel. A focused 1080×720 runtime benchmark measured approximately
  1.33 ms median and 1.97 ms p95 kernel-plus-`CGImage` render latency on the
  development machine.
- Bounded latest-value-wins still-preview scheduling with at most one render in
  flight and one newest pending parameter snapshot.
- Display-rate coalescing with a 17 ms inter-frame delay, capping renders at
  ~60 Hz and preventing render backlog during rapid slider interaction.
  Verified by scheduling contract tests (coalescing, latest-value-wins,
  cancellation, bounded backlog) and a 500-update GPU burst benchmark
  (1080×720 proxy, p95 2.89 ms).
- Per-file, session-scoped SwiftUI correction controls for film mode,
  orientation, temperature, tint, gamma, shadows, highlights, and saturation,
  plus reset and original/corrected comparison.
- Exact threshold generation from 16-bit BGR images matching Python `get_threshold`
  for five dark/light parameter combinations. Covers `convertScaleAbs` (16-to-8
  bit), BGR-to-grayscale via OpenCV fixed-point coefficients, `inRange` binary
  thresholding, and 7×7 binary erosion (2 iterations) with default border handling.
- `shrink_box` coordinate math for crop-box adjustment, matching Python
  float32-precision arithmetic and OpenCV `boxPoints` ordering.
- Float64 NPY fixture loading support for intermediate floating-point pipeline
  stages, with SHA-256 verification.
- Exact white balance coefficient adjustment (`wb_adjust_coeff`) matching Python
  float64 multiplication for neutral, warm, cool, and extreme temperature/tint
  settings.
- Saturation adjustment (`sat_adjust`) via RGB↔HSV conversion, matching Python
  float32-precision HSV math with documented ≤1 LSB tolerance after conversion
  back to 16-bit. Inputs are clipped to Python's normalized range before HSV
  conversion, including highlights pushed above 65535 by white balance. Covers
  neutral, boosted, reduced, grayscale, max saturation, and over-range values.
- Histogram equalisation with exact float64 pixel equality for three fixtures
  (B&W negative, colour negative, slide with base detect). Per-channel percentile
  computation, black-point offset, and white-point scaling with sensitivity=0.2.
- Exposure adjustment matching Python's float32 rounding boundaries exactly.
  Covers neutral normalization and clipping, gamma, shadows, highlights, and
  combined adjustments.
- Optional AVFoundation live camera preview.
- GPU-backed live preview inversion, exposure, and saturation controls.
- Late-frame dropping and a 20 FPS processing throttle.
- Camera permission metadata embedded in the executable.
- macOS CI that runs Swift tests and builds the app.
- Python CI that protects the production reference implementation.

## Important Limitations

- Standard images with alpha channels are rejected because the current
  processing pipeline supports grayscale and three-channel BGR buffers.
- Exact standard-decode equivalence is currently locked for the committed PNG,
  BMP, and TIFF fixtures. JPEG is locked to the documented tolerance above.
  Broader real-file coverage, including embedded color profiles and orientation
  metadata, remains to be added to the frozen corpus.
- Standard and RAW images now enter the engine, but most correction stages after
  decoding are not implemented yet. Completed: threshold generation, white
  balance coefficient adjustment, saturation adjustment, exposure, histogram
  equalisation, and `shrink_box` coordinate math.
- Interactive previews do not yet integrate histogram equalisation, film-base
  detection, crop detection, perspective correction, dust removal, or
  persistence across launches. They are suitable for evaluating the current
  correction interaction and loaded-file flow, not final output. Export
  follows.
- Still-image slider bindings and the initial GPU correction renderer are
  implemented with bounded latest-value-wins scheduling and display-rate
  coalescing (17 ms inter-frame delay). GPU-vs-CPU algorithmic equivalence
  is verified across 696 parameter combinations. p95 GPU kernel-to-CGImage
  latency is 2.89 ms at 1080×720 (well under the 33 ms gate). A Metal-backed
  preview surface, display-rate coalescing for the full display path, and idle
  authoritative rendering remain. See the
  [real-time still preview plan](realtime-preview-plan.md).
- Several intermediate Python pipeline stages use float32 arithmetic
  (`cv2.boxPoints`, `matplotlib.colors.rgb_to_hsv`). Swift implementations
  using Double (float64) must cast to Float for precision-sensitive comparisons
  or accept documented ≤1 LSB tolerance after conversion back to 16-bit.
- The representative RAF files remain outside version control. Their compact
  RawPy hashes are committed, so local runs with `sample-raw/` prove exact
  equivalence; CI compiles and exercises non-corpus decoder contracts.
- Half-resolution native RAW decode performance is effectively equal to RawPy.
  Full-resolution native decode is currently about 19.7% slower because the
  bridge and Swift ownership boundary copy the approximately 241 MB output
  twice. See the benchmark report before changing this path.
- Live camera preview works only when macOS exposes the DSLR or capture adapter
  as an AVFoundation video device. Many DSLRs require a vendor SDK or tethering
  adapter for live view.
- Live camera preview is an 8-bit alignment and correction aid. Final output
  must continue to use the full 16-bit RAW capture and pixel-equivalent pipeline.
- The Python application remains the working production application.

The native test suite currently contains **95 tests** across 10 test files,
all passing on macOS 15.

## Completed Native Features (newly added)

- Overall RGB tone curve with piecewise-linear interpolation, stored as
  16-bit 65536-entry LUTs. Per-channel red, green, and blue curves fall back
  to the overall curve; identity when no curve is enabled.
- Highlight, midtone, and shadow color wheels. Each wheel maps a hue angle
  and strength to an RGB gain vector applied through a smoothstep tonal mask:
  highlights respond above 0.3 luminance (peak at 1.0), midtones peak at 0.5
  (zero at 0.0 and 1.0), and shadows respond below 0.7 (peak at 0.0).
  Luminance is preserved after wheel application.
- GPU preview kernel: curve LUT passed as a 256×256 8-bit CIImage sampler;
  color wheel masks and gain math mirrored in the Core Image Kernel Language.
- GPU-versus-CPU equivalence verified for curves, color wheels, and both
  combined (Float vs Double precision, ≤2 LSB per pixel, ≤64 8-bit levels).
  B&W negative correctly skips curves and color wheels in both CPU and GPU
  paths. 35 tests cover LUT construction (identity, unsorted input, duplicate
  inputs, extrapolation, boundaries), mask ranges and overlap, hue wrapping,
  zero-strength identity, three simultaneous wheels, and full GPU-CPU
  equivalence.

## Next Work

Work should proceed in this order:

1. ~~Add a failing threshold-generation fixture, then port threshold generation
   with exact pixel equality.~~ Done.
2. ~~Port white balance coefficient adjustment.~~ Done.
3. ~~Port saturation adjustment with documented float tolerance.~~ Done.
4. ~~Port exposure (gamma + shadows/highlights polynomials).~~ Done.
5. ~~Implement the [real-time still preview plan](realtime-preview-plan.md), with
   live slider bindings, a GPU-backed still preview, latest-value-wins
   scheduling, display-rate coalescing, and a 500-update burst benchmark.~~ Done.
   Stages 0–3 complete. Stage 4 (Metal-backed surface + idle authoritative
   render) deferred.
6. ~~Port histogram equalisation (percentile computation + channel scaling).~~ Done.
   Exact float64 equality for 3 fixtures.
7. ~~Implement authoritative overall/per-channel RGB curves and
   highlight/midtone/shadow color wheels, then add matching GPU preview
   controls and visual-equivalence tests.~~ Done. 19 tests covering curve LUT
   construction, mask ranges, per-channel isolation, luminance preservation,
   and GPU-vs-CPU equivalence for curves, wheels, and combined.
8. Implement TIFF/JPEG/PNG export and the defined processed-RGB DNG contract,
   including metadata, round-trip, cancellation, and batch-export tests.
9. Port contour detection and crop box computation (requires OpenCV C++ interop
   for `findContours` + `minAreaRect`).
10. Port perspective warp (DLT homography solve + bilinear warp).
11. Port dust detection and Telea FMM inpainting (requires OpenCV interop or
    custom Metal kernel).
12. Expand the frozen corpus to cover intermediate stages and parameter-grid
   variants.
13. ~~Connect completed engine stages to the SwiftUI preview panel.~~ Initial
    correction prototype complete; finish real-time verification, then expand
    it as new engine stages land.

Do not expand the SwiftUI control surface ahead of the engine unless the work
directly enables testing or validates an important workflow.

## Build And Test

The native package requires macOS 14 or later and Homebrew LibRaw:

```sh
brew install libraw
```

```sh
swift test --package-path native/FilmScanEngine
swift build --package-path native/FilmScanEngine --product FilmScanConverterMac
swift run --package-path native/FilmScanEngine FilmScanConverterMac
```

Generate the currently committed Python reference fixtures:

```sh
.venv/bin/python tests/generate_native_snapshots.py
.venv/bin/python tests/generate_raw_decode_reference.py
```

Run the Python regression suite:

```sh
.venv/bin/python -m unittest discover -v
```

## Development Rules

- Write the equivalence or behavior test before implementing a native stage.
- Require exact pixel equality first. Document any unavoidable tolerance before
  accepting it.
- For native-only features such as curves and color wheels, define and freeze
  the authoritative CPU behavior before implementing the GPU preview or UI.
- Keep live preview explicitly separate from final-quality RAW processing.
- Update this page when the active development step or implemented scope changes.
- Be aware of float32 precision in the Python pipeline: `cv2.boxPoints` returns
  float32, and `matplotlib.colors.rgb_to_hsv` operates in float32 internally.
  Swift implementations using `Double` (float64) must match precision via
  `Float` casts or accept documented tolerance for intermediate stages.
- The Python `shrink_box` uses `np.where(box==topleft)[0][0]` which does
  element-wise matching (not row-wise). This is benign for the output but
  must be replicated exactly for pixel equivalence.
