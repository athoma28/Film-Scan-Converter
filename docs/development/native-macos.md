# Native macOS Development

This page is the authoritative status for the Swift/macOS rewrite. It describes
what works now, the current development step, and the order of upcoming work.
The detailed [macOS native roadmap](../improvements/MacOS-Native-Roadmap.md) is
the design reference, not a statement that every listed item is implemented.

**Last updated:** 2026-06-14

## Goal

Build a native Swift and SwiftUI version of Film Scan Converter that:

- produces pixel-equivalent final exports from the same RAW inputs and settings;
- improves preview and batch-processing performance;
- provides a modern macOS interface without removing the existing Python app
  before the native replacement is ready;
- provides a low-latency corrected camera preview when the DSLR or capture
  adapter exposes a video feed to macOS.

## Current Development Step

**Active step: Phase 1.8, exposure complete. Next: histogram equalisation.**

Threshold generation (Phase 1.2) is complete with exact pixel equality across
five dark/light parameter combinations. Coordinate math (`shrink_box`) is
ported. White balance (`wb_adjust_coeff`) is complete with exact float64
equality. Saturation adjustment (`sat_adjust`) is complete with documented
≤1 LSB floating-point tolerance (standard for HSV conversion stages). Float64
NPY fixture infrastructure is in place. Exposure is complete with exact
float32-rounding equivalence across gamma, shadows, highlights, clipping, and
combined adjustments. The next work is histogram equalisation and contour
detection.

## Progress

| Area | Status | Current result |
|---|---|---|
| Phase 0: regression gate | In progress | Swift tests consume frozen Python-generated `.npy` fixtures and compact RAW hash manifests. Standard decode fixtures cover 8-bit PNG, grayscale PNG, BMP, JPEG, and 16-bit TIFF. Five half-size RAF decodes and one full-resolution RAF decode require exact SHA-256 equality with RawPy when the local `sample-raw` corpus is present. The full intermediate-stage and parameter-grid corpus is not complete. |
| Phase 1: processing engine | In progress | `FilmScanEngine` decodes standard images and RAW files, with pixel-equivalent rotate, flip, frame, and aspect-ratio helpers. Threshold generation is complete with exact pixel equality for 5 dark/light parameter combinations. White balance (`wb_adjust_coeff`) is complete with exact float64 equality for 4 temp/tint settings. Saturation adjustment (`sat_adjust`) is complete with documented ≤1 LSB float tolerance for 5 saturation levels. Exposure is complete with exact float32-rounding equality for 5 parameter combinations. `shrink_box` coordinate math is ported. The remaining correction pipeline (histogram equalisation, crop detection, perspective warp, dust detection/inpainting) is not implemented yet. |
| Phase 2: accelerated rendering | Prototype only | Live camera preview uses a Metal-backed Core Image context for fast inversion, exposure, and saturation. This is not the final pixel-equivalent processing pipeline. |
| Phase 3: SwiftUI application | Early shell | The app builds, accepts supported files by drag and drop, decodes and previews standard images and RAW files through `FilmScanEngine`, and exposes optional live camera preview controls. |
| Phase 4: performance and polish | Early measurement | CI builds and tests the current native package. The representative RAW decode and quality benchmark is complete; packaging, UI snapshots, and release work remain. |

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
  back to 16-bit. Covers neutral, boosted, reduced, grayscale, and max
  saturation levels.
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
  balance coefficient adjustment, saturation adjustment, exposure, and
  `shrink_box` coordinate math.
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

The native test suite currently contains **41 tests** across 8 test files,
all passing on macOS 15.

## Next Work

Work should proceed in this order:

1. ~~Add a failing threshold-generation fixture, then port threshold generation
   with exact pixel equality.~~ Done.
2. ~~Port white balance coefficient adjustment.~~ Done.
3. ~~Port saturation adjustment with documented float tolerance.~~ Done.
4. ~~Port exposure (gamma + shadows/highlights polynomials).~~ Done.
5. Port histogram equalisation (percentile computation + channel scaling).
6. Port contour detection and crop box computation (requires OpenCV C++ interop
   for `findContours` + `minAreaRect`).
7. Port perspective warp (DLT homography solve + bilinear warp).
8. Port dust detection and Telea FMM inpainting (requires OpenCV interop or
   custom Metal kernel).
9. Expand the frozen corpus to cover intermediate stages and parameter-grid
   variants.
10. Connect completed engine stages to the SwiftUI preview panel.

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
- Keep live preview explicitly separate from final-quality RAW processing.
- Update this page when the active development step or implemented scope changes.
- Be aware of float32 precision in the Python pipeline: `cv2.boxPoints` returns
  float32, and `matplotlib.colors.rgb_to_hsv` operates in float32 internally.
  Swift implementations using `Double` (float64) must match precision via
  `Float` casts or accept documented tolerance for intermediate stages.
- The Python `shrink_box` uses `np.where(box==topleft)[0][0]` which does
  element-wise matching (not row-wise). This is benign for the output but
  must be replicated exactly for pixel equivalence.
