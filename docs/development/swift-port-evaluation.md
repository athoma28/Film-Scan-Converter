# Swift Port Evaluation

**Date:** 2026-06-14 (updated 2026-06-14)
**Scope:** Complete review of the native Swift/macOS rewrite against the
production Python/Tkinter application, covering architecture, implemented
features, code quality, test coverage, and remaining work.

The authoritative current-step page is [Native macOS Development](native-macos.md).
The longer-term technical design is in [macOS Native Roadmap](../improvements/MacOS-Native-Roadmap.md).
This document is an independent top-to-bottom evaluation, not a replacement for
either.

---

## 1. Architecture

The native package is a Swift Package Manager project at `native/FilmScanEngine`
with five targets layered cleanly:

```
CLibRaw (system library, pkg-config → Homebrew libraw)
  └─ CLibRawShim (C shim, 152 lines)
       └─ FilmScanEngine (pure Swift library, 10 files / ~940 lines)
            ├─ FilmScanConverterMac (SwiftUI app shell, 5 files / ~420 lines)
            ├─ FilmScanRawBenchmark (CLI benchmark, 1 file / ~143 lines)
            └─ FilmScanEngineTests (swift-testing, 10 files / ~930 lines)
```

**Dependency strategy:**
- RAW decode: Thread-safe LibRaw via a narrow C shim with no LibRaw lifetime
  leakage. The shim handles BGR channel reorder and LibRaw initialisation exactly
  matching RawPy defaults (demosaic=2, colour_space=7, gamma=(2.222,4.5),
  use_camera_wb, half-size proxy).
- Standard image decode: ImageIO + Core Graphics 16-bit bitmap contexts.
- Image helpers: Pure Swift loops for rotation, flip, frame, aspect-ratio pad.
- Threshold: Pure Swift with OpenCV-equivalent fixed-point arithmetic.
- Coordinate math: Pure Swift with Float32-precision comparison.
- White balance: Pure Swift with float64 vector multiplication.
- Saturation: Pure Swift with Float32-precision RGB↔HSV conversion.
- Exposure: Pure Swift with Python-equivalent Float32 rounding boundaries.
- Camera preview: AVFoundation + Metal-backed Core Image (separate from engine).
- No external Swift dependencies. Only system frameworks and Homebrew LibRaw.

**Design judgments that are correct:**
- The engine library (`FilmScanEngine`) has zero UI dependencies and is
  `Sendable` throughout, which keeps it testable and separable from the app.
- The live camera preview pipeline is explicitly decoupled from the
  pixel-equivalent processing pipeline. This prevents the correctness gate from
  being undermined by the prototype.
- The C shim copies pixels into an owned `malloc` buffer that Swift copies again
  into `[UInt16]`. This double-copy explains the ~19.7% full-resolution decode
  slowdown versus RawPy (documented in `native-raw-benchmark.md`), but is a safe
  default until a single-copy path is proven correct.
- Background decoding uses `Task.detached(priority: .userInitiated)` so
  full-resolution imports do not block the main actor.

---

## 2. What Is Implemented (With Quality Assessment)

### 2.1 LibRaw C Bridge — `CLibRawShim.c` (152 lines)

**Status: Complete. Quality: High.**

Matches the Python `RawProcessing.load()` parameter set line-for-line. Handles
all LibRaw lifecycle correctly (init → open → unpack → dcraw_process →
make_mem_image → free). The BGR reorder loop and `color_description` extraction
match RawPy output byte-for-byte. Error paths all free LibRaw state and report
through a 512-byte error buffer that Swift converts to `LocalizedError`.

### 2.2 Standard Image Decoder — `StandardImageDecoder.swift` (140 lines)

**Status: Complete. Quality: High.**

Handles 8-bit PNG, 8-bit grayscale PNG, 8-bit BMP, 8-bit JPEG, and 16-bit TIFF.
Routes through `CGImageSource` → `CGImage` → `CGContext` with 16-bit
destinations. The `pythonScaled` function replicates OpenCV's `uint8 → uint16`
scaling (`value * 256` for 8-bit sources). BGR channel ordering is handled at
the pixel packing stage (RGBA → BGR). Alpha channels are rejected explicitly.

Coverage gaps (acknowledged in `native-macos.md`): embedded color profiles and
orientation metadata are not yet in the frozen corpus.

### 2.3 `UInt16Image` — `UInt16Image.swift` (116 lines)

**Status: Complete. Quality: High.**

The core data type. `Equatable`, `Sendable`, with precondition-guarded
initialisers. Rotation (0/90/180/270) and horizontal flip through coordinate
remapping. Frame and aspect-ratio padding via `padded(top:bottom:left:right:)`.
All operations are pure Swift with no external dependencies.

The `makePreviewCGImage()` extension (42 lines) produces an 8-bit RGBA `CGImage`
from either 1-channel or 3-channel BGR `UInt16Image` buffers. Used by
`AppModel` for SwiftUI `Image(nsImage:)` display.

### 2.4 Processing Parameters — `ProcessingParameters.swift` (75 lines)

**Status: Complete. Quality: Adequate.**

Defines `FilmType` (b&w negative, colour negative, slide, crop-only),
`ProcessingParameters` (all user-facing controls), `RenderParameters` (frame +
aspect ratio), and `AspectRatio`. All are `Codable`, `Equatable`, `Sendable`.

Missing from the Python equivalent: advanced parameters (`max_proxy_size`,
`dm_alg`, `colour_space`, `raw_gamma`, `use_camera_wb`, `wb_mult`, `fbdd_nr`,
`noise_thr`, `median_filter_passes`, `dust_threshold`, `max_dust_area`,
`dust_iter`, `picker_radius`, `histogram_plt_size`, `hist_bg_colour`,
`jpg_quality`, `tiff_compression`, `black_point_percentile`,
`white_point_percentile`, `ignore_border`, `ignore_neg_border`, `exp_shift`).
Also missing: `base_detect`, `base_rgb`, `dark_threshold`, `light_threshold`,
`reject` — these are user-facing processing params present in the Python
`processing_parameters` tuple but absent from the Swift struct.

### 2.5 File Drop Policy — `FileDropPolicy.swift` (20 lines)

**Status: Complete. Quality: High.**

Case-insensitive extension matching, deduplication by canonical path while
preserving insertion order. Correctly separates RAW and standard-image
extensions.

### 2.6 Live Preview Throttle — `LivePreviewThrottle.swift` (23 lines)

**Status: Complete. Quality: High.**

Simple, correct frame-rate limiter. Handles clock resets correctly (negative
elapsed → accept frame), which is important for AVFoundation presentation
timestamps that can wrap.

### 2.7 SwiftUI App Shell — `FilmScanConverterMac/` (5 files, ~420 lines)

**Status: Early shell. Quality: Adequate.**

| File | Lines | Assessment |
|------|-------|------------|
| `FilmScanConverterMacApp.swift` | 22 | Minimal `@main` entry. Replaces `CommandGroup(.newItem)` with Import Files (`Cmd+O`). |
| `ContentView.swift` | 108 | `NavigationSplitView` with sidebar list + detail preview. Drag-and-drop with visual feedback. Live camera toggle with exposure/saturation sliders in toolbar. |
| `AppModel.swift` | 88 | `@MainActor ObservableObject`. File import → dedup → background decode → preview. Status bar text. `NSOpenPanel` import fallback. |
| `CameraController.swift` | 197 | AVFoundation capture session. External device preferred, fallback to built-in. Core Image inversion/exposure/saturation on GPU. 20 FPS throttle. Thread-safe settings via `NSLock`. |
| `Info.plist` | — | Embedded via linker flag. Camera usage description. |

### 2.14 Fixture Loader — Extended

**Status: Solid. Quality: High.**

Extended beyond uint16 NPY support with `loadFloat64Case()` for float64 `.npy`
files, enabling intermediate floating-point pipeline stage testing. The
`parseNPYHeader` function was factored out for reuse. Float64 data is read
directly via `Data.copyBytes` into `[Double]`. SHA-256 verification works on
raw byte representation. Current support: `<u2` (uint16) and `<f8` (float64).

### 2.15 Test Infrastructure

**Status: Solid. Quality: High.**

| Test file | Lines | Tests | Coverage |
|-----------|-------|-------|----------|
| `FixtureLoader.swift` | 135 | NPY parser (uint16 + float64) with SHA-256 verification | Fixture I/O |
| `StandardImageDecoderTests.swift` | 95 | PNG8, BMP8, JPEG8 (tolerance), TIFF16, grayscale PNG8, RAW rejection, preview CGImage | All standard decode paths |
| `RawImageDecoderTests.swift` | 94 | 5-RAF half-res corpus (exact SHA-256), 1 RAF full-res, standard-image rejection, missing file | All RAW decode paths |
| `UInt16ImageTests.swift` | 50 | Rotation+flip equivalence, frame+aspect equivalence, parameters JSON round-trip | All helper operations |
| `ThresholdTests.swift` | 55 | 5 dark/light fixtures, exact pixel equality, 1-channel output | All threshold paths |
| `CoordinateMathTests.swift` | 60 | 7 box/shrink cases, Float32-precision | All shrink_box paths |
| `ProcessingTests.swift` | 120 | 4 WB fixtures (exact float64), 5 saturation fixtures (≤1 LSB tolerance) | WB + SAT paths |
| `InputAndLivePreviewTests.swift` | 58 | Drop admission, deduplication, extension consistency, frame throttle (including clock reset) | Input + preview contracts |

The test suite has been migrated from XCTest to `swift-testing`. Tests consume
Python-generated `.npy` fixtures frozen by `tests/generate_native_snapshots.py`
and `tests/generate_raw_decode_reference.py`. The fixture format includes
SHA-256 hashes that are verified at load time, preventing fixture corruption.
Tests are designed to pass in CI without the `sample-raw/` corpus (they skip
RAF-specific tests when files are absent).

### 2.9 CI — `.github/workflows/native-engine.yml`

**Status: Operational. Quality: Adequate.**

Runs `swift test` and `swift build` on `macos-15` for any push/PR touching
`native/**` or the Python fixture generators. Triggers on Homebrew-based LibRaw.

### 2.10 Benchmark Tool — `FilmScanRawBenchmark/main.swift`

**Status: Complete. Quality: High.**

Repeated decode with timing (median + best), pixel SHA-256, quality metrics
(min/max/mean/clip %). Outputs structured JSON for comparison tooling. Used by
`tests/compare_raw_decode_benchmarks.py`.

### 2.11 Threshold Generation — `UInt16Image+Threshold.swift` (~110 lines)

**Status: Complete. Quality: High.**

Ports `RawProcessing.get_threshold()` with exact pixel equality. The pipeline:
1. `convertScaleAbs(alpha=255/65535)` → `(v + 128) / 257` (correctly rounds)
2. `cvtColor(BGR2GRAY)` → OpenCV fixed-point: `(1868·B + 9617·G + 4899·R + 8192) >> 14`
3. `inRange(low, high)` → `gray >= dt+1 && gray <= lt`
4. `erode(7×7, 2 iterations)` → manual binary erosion with default border (off-image = 255)

Uses pure Swift integer/float arithmetic. No Accelerate/vImage dependency yet
(correctness-first; vImage can replace in Phase 2). Verified against 5
dark/light parameter combinations on an 80×100 structured synthetic image.

### 2.12 Coordinate Math — `CoordinateMath.swift` (~120 lines)

**Status: Complete. Quality: High.**

Ports `RawProcessing.shrink_box()` — a pure coordinate function that shrinks a
4-point crop box inward by x%/y%. Replicates Python float32 precision by
converting to `Float` and back for key comparisons (`min(key:sum)` and
`np.where` element matching).

Critical discovery: `cv2.boxPoints` returns float32, and the `min(key=sum)`
comparison depends on float32 precision. Two sums that differ only beyond
float32 precision (e.g., 257.573608 vs 257.573601) are equal in float32 but
unequal in float64, changing which point is selected as "topleft." The
implementation handles this via `Double(Float(value))` for comparison
operations. Verified against 7 test cases spanning 0° through 45° rotations
with expand, contract, and identity shrink operations.

### 2.13 Film Processing — `Processing.swift` (~150 lines)

**Status: Partial (WB, saturation, and exposure complete). Quality: High.**

Contains three completed pipeline stages:

**White balance (`wb_adjust_coeff`):** Exact float64 equality with Python for
4 temp/tint combinations (neutral, warm 65/-40, cool -30/20, extreme 100/-100).
Three-coefficient per-channel multiplication: `B*(1-temp/200+tint/400)`,
`G*(1-tint/200)`, `R*(1+temp/200+tint/400)`. Neutral WB (temp=0, tint=0)
returns input unchanged. No float32/float64 divergence since only basic
multiplication is involved.

**Saturation (`sat_adjust`):** Documented ≤1 LSB tolerance with Python for
5 saturation levels (100, 150, 50, 0, 200). Full RGB↔HSV conversion using
Float32-precision math to match Python's `matplotlib.colors.rgb_to_hsv`
(which internally uses float32). HSV formulas: standard `V=max(R,G,B)`,
`S=delta/V`, 6-sector hue, with H normalized to [0,1]. After sat adjustment
(S *= factor, clipped to [0,1]), HSV→RGB inverse transform. Tolerance is 0.5
absolute in float64 space — well within the ≤1 LSB roadmap policy for
floating-point stages.

**Exposure (`exposure`):** Exact equality with Python for 5 fixture cases
covering neutral normalization and clipping, gamma, shadows, highlights, and
combined adjustments. The implementation preserves Python's Float32 rounding
after normalization, gamma, each polynomial adjustment, and final scaling.

Histogram equalisation is not yet implemented.

### 2.14 Fixture Loader — Extended

---

## 3. What Remains — Ordered Implementation Plan

### 3.1 Phase 1.2: Threshold Generation — COMPLETE

Port of `RawProcessing.get_threshold()` is implemented in
`UInt16Image+Threshold.swift`. Exact pixel equality verified against 5
dark/light parameter combinations on an 80×100 structured synthetic image.
The implementation uses pure Swift arithmetic:
- `convertScaleAbs(alpha=255/65535)`: `(v + 128) / 257`
- BGR→Gray: `(1868·B + 9617·G + 4899·R + 8192) >> 14`
- `inRange`: `gray >= dt+1 && gray <= lt`
- `erode(7×7, 2 iterations)`: manual binary erosion, border = 255

`shrink_box()` coordinate math is also complete in `CoordinateMath.swift`,
matching Python float32 precision.

### 3.2 Phase 1.2 cont.: Contour Detection & minAreaRect

**Highest-risk port in the project.**

`findContours(RETR_EXTERNAL, CHAIN_APPROX_SIMPLE)` plus `minAreaRect()` are the
functions most likely to diverge from OpenCV. The roadmap identifies three
options:

1. **OpenCV C++ interop** (recommended for pixel equivalence): Add a C++ bridging
   layer that calls `cv::findContours` and `cv::minAreaRect` directly. Requires
   `brew install opencv`, a C++ bridging header, module map, and linking
   `libopencv_imgproc` + `libopencv_core`. This is the safest path — guarantees
   bit-identical output for the same pixel input.

2. **Manual Suzuki-Abe + rotating calipers**: ~300 lines of careful
   boundary-following code. Must replicate OpenCV's exact pixel traversal order
   and coordinate rounding. The `minAreaRect` rotating calipers algorithm is
   well-defined but sensitive to floating-point ordering.

3. **Vision framework `VNDetectContoursRequest`**: Returns a different contour
   format and different hierarchy. Will not produce pixel-equivalent results.

**Recommendation:** Use OpenCV interop for `findContours` + `minAreaRect` (and
also for `inpaint` Telea FMM in phase 1.9). These are the only two functions
where a manual port adds significant risk with no benefit. The build cost is
well-understood (`brew install opencv`, bridging header). Accept the dependency
for correctness, then optionally replace with Metal in Phase 2.

`shrink_box()` is pure coordinate math and can be ported directly to Swift.

### 3.3 Phase 1.3: Perspective Warp

Port `RawProcessing.crop()`:

```
getPerspectiveTransform(4 pts)    → DLT homography via SVD (Accelerate LAPACK)
warpPerspective(bilinear)         → vImage for 8-bit; Metal compute kernel for 16-bit
```

The DLT solver requires solving `Ah = 0` from 4 point correspondences (8
equations). Use `LAPACK`'s `DGESVD` via Accelerate. The `warpPerspective`
must use `INTER_LINEAR` with `WARP_INVERSE_MAP` semantics. 16-bit warping needs
a Metal compute kernel (vImage warp only supports 8-bit).

### 3.4 Phase 1.4: Histogram Equalisation

Port `RawProcessing.hist_EQ()`:

```
np.percentile(linear)             → vDSP sort + linear interpolation between bins
np.divide(where=white_point>0)    → vDSP.divide with zero guard
np.multiply(white_multipliers)    → vDSP.multiply
```

The linear interpolation logic in `np.percentile` must be replicated exactly:
sort the sample values, compute fractional index `(pct/100) * (N-1)`, linear
interpolate between floor and ceil indices. The caching scheme
(`_histogram_stats_signature`, `_histogram_black_offsets`,
`_histogram_white_point`) must be ported with `Hashable` structs tracking
`_raw_revision` and all input parameters.

### 3.5 Phase 1.5: White Balance — `wb_adjust_coeff` — COMPLETE

Port is in `Processing.swift` with exact float64 equality for 4 temp/tint
combinations. The implementation is a straightforward three-coefficient
per-channel multiplication using `Double` arithmetic. No float32/float64
divergence occurs since only basic multiplication is involved. The WB picker
logic (compute mean over masked circle → solve for temp/tint) has not yet
been ported.

### 3.6 Phase 1.6: Exposure — COMPLETE

Port is in `Processing.swift` with exact Python Float32-rounding equivalence.
The implementation preserves the empirical coefficients (`4.15e-5`,
`0.02185`) and is verified for clipping, gamma, shadows, highlights, and
combined adjustments.

### 3.7 Phase 1.7: Saturation — `sat_adjust` — COMPLETE

Port is in `Processing.swift` with documented ≤1 LSB tolerance. The
implementation uses Float32-precision RGB↔HSV conversion to match Python's
`matplotlib.colors.rgb_to_hsv` (which internally operates in float32). The
HSV formulas use standard math: `V=max(R,G,B)`, `S=delta/V`, 6-sector hue
normalized to [0,1]. After multiplying S by the saturation factor and clipping,
HSV→RGB inverse transform produces the result. Tolerance is 0.5 absolute in
float64 space (well within ≤1 LSB). Verified for 5 saturation levels: 100
(neutral), 150 (boosted), 50 (reduced), 0 (grayscale), 200 (max).

### 3.8 Phase 1.8: Dust Detection — `find_dust`

Port:

```
convertScaleAbs                → vImageConvert_16UTo8U
cvtColor(BGR2GRAY)             → weighted sum (same as threshold)
np.percentile(0.5, 99.5)       → vDSP sort + linear interpolate (same as hist_EQ)
threshold(BINARY_INV)          → vImage lookup table
dilate(kernel, dust_iter)      → vImageDilate_Planar8 (repeated)
erode(kernel, dust_iter)       → vImageErode_Planar8 (repeated)
findContours(area filter)      → OpenCV interop (same contours code as 1.2)
drawContours(FILLED)           → OpenCV interop
dilate(1 iter)                 → vImageDilate_Planar8
```

### 3.9 Phase 1.9: Dust Inpainting — `fill_dust`

**The single hardest function to port with pixel equivalence.**

`cv2.inpaint(INPAINT_TELEA, radius=3)` applied per-channel (channels split,
inpainted separately, merged). Options:

1. **OpenCV C++ interop** (recommended): Single call to `cv::inpaint` with
   `cv::INPAINT_TELEA`. Guarantees pixel equivalence. Same bridging layer as
   contour detection.

2. **Custom Metal compute kernel**: Telea FMM as a multi-pass GPU kernel. ~500
   lines of shader code. High performance payoff but significant implementation
   risk.

3. **Replace with median blur**: Loses pixel equivalence, requires regenerating
   the reference corpus.

**Recommendation:** Start with OpenCV interop (correctness), then pursue Metal
in Phase 2 (performance).

### 3.10 Phase 1.10: Caching

Port the three-tier cache invalidation from `RawProcessing.py`:

- `_raw_revision`: incremented on every `load()`.
- `_dust_signature`: tuple of (raw_revision, img.shape, rect, border_crop, ignore_border, dust_threshold, max_dust_area, dust_iter). Checked before `find_dust()`.
- `_histogram_stats_signature`: tuple of (raw_revision, img.shape, rect, border_crop, film_type, base_detect, base_rgb, ignore_border, ignore_neg_border, black_point_percentile, white_point_percentile, black_point). Checked before the percentile computation.

Swift implementation: `Hashable` structs with `Equatable` conformance for each
signature type. Store alongside the cached results.

### 3.11 Phase 1.11: Batch Export

Port Python's `multiprocessing.Pool` export strategy:

- `OperationQueue` with `maxConcurrentOperationCount` determined by
  `os_proc_available_memory()` ÷ per-photo memory estimate.
- Each operation: reload file → decode → process → write.
- `Operation.isCancelled` checked between stages.
- Deterministic progress reporting (current/total count).
- Error collection (do not abort on first failure).
- Partial output cleanup on cancellation.

### 3.12 Phase 2: Metal Acceleration (Performance)

All of this is forward-looking. The engine must be correct before it is fast.

| Kernel | Purpose | Performance target |
|--------|---------|--------------------|
| `warpPerspective` | 16-bit bilinear warp from homography | < 5 ms for 4K×4K |
| `inpaint` | Telea FMM multi-pass solver | < 20 ms for 4K, 3 channels |
| `histogramEqualization` | Per-channel histograms via `atomic_uint`, apply LUT | < 5 ms |
| `exposureAndColour` | Fused gamma + shadows + highlights + WB + saturation | Eliminates intermediate buffers |

Use `MTLStorageModeManaged` for CPU↔GPU transfers. Stream large images in tiles
if needed (unlikely at 6K×4K 16-bit = 144 MB).

### 3.13 Phase 3: SwiftUI Application

The current shell is minimal. The full application must provide:

**Sidebar inspector (scrollable, collapsible sections):**
- Photo selector: Combobox→`Picker` with selection binding. Import/prev/next/remove.
- Processing: Film type `Picker`, reject `Toggle`, dust removal `Toggle`, global sync `Toggle`.
- Crop & rotate: Threshold sliders, border crop slider, flip toggle, rotation buttons (90° CW/CCW).
- Colour: Base detection mode `Picker`, base RGB display + color swatch + picker, WB picker button, temp/tint/saturation sliders.
- Brightness: White point, black point, gamma, shadows, highlights sliders.
- Export: File type `Picker` (TIFF/JPEG/PNG), frame slider, aspect ratio `Picker`, folder selector, export buttons (individual/batch).

**Preview area:**
- Process view switcher: `Picker(.segmented)` for RAW / Threshold / Contours /
  Histogram / Full Preview.
- Upper panel: intermediate-stage preview (smaller).
- Lower panel: final-stage preview (larger).
- Crop overlay: draw `boxPoints` rectangle and `EQ_ignore` shaded region.
- Histogram overlay: draw per-channel histogram bars when in Histogram mode.
- Click-to-pick: WB base point and base colour on preview image.
- Zoom/pan: `NSScrollView` with pinch-to-zoom and drag-to-pan (not present in
  Python app).

**Export workflow:**
- Determinate `ProgressView` with current/total count.
- Abort button.
- Per-file error log in expandable details.

**Settings management:**
- Copy/paste settings between photos (`Cmd+C` / `Cmd+V`).
- Reset to defaults.
- Save/load named presets.
- Drag-to-reorder photos in sidebar.
- Undo/redo via `UndoManager` on `DocumentModel`.

**Must-have UX improvements (done during port):**
- Live preview zoom/pan (Python had none).
- Before/after split view.
- Keyboard shortcut reference overlay (`Cmd+/`).
- Dark mode (free via SwiftUI).
- Undo/redo on all parameter changes.

### 3.14 Phase 4: Performance Gates & Polish

| Metric | Target | Current |
|--------|--------|---------|
| Cold pipeline (6K RAW→export) | ≥ 3× faster than Python | Not yet measurable (no pipeline) |
| Warm pipeline (cached) | ≥ 5× faster than Python | Not yet measurable |
| Full batch (10× 6K RAW) | ≥ 4× faster than Python | Not yet measurable |
| Memory per photo | ≤ Python baseline | Not yet measured |
| RAW decode half-size | ≥ 2× faster than RawPy | **0.99x** (marginally slower) |
| RAW decode full-size | ≥ 1× RawPy | **0.84x** (~19.7% slower) |

The full-resolution decode gap is the first measurable performance problem.
Eliminating the double-copy through a single-allocation bridge path is
well-understood and low-risk.

**Packaging:**
- Code signing and notarisation (required for distribution outside App Store).
- DMG creation.
- Sparkle update framework integration.
- App sandbox considerations (camera + file access entitlements).

**CI expansion:**
- Performance benchmarks (opt-in, compare to stored baseline, warn > 10%
  regression).
- UI snapshot tests via `pointfreeco/swift-snapshot-testing`.
- Full frozen corpus coverage (synthetic images, all intermediate stages,
  parameter-grid variants).

---

## 4. Code Quality Observations

**Strengths:**
- The C shim is clean, defensive, and has no memory leaks. Error handling
  reports through the error buffer in every failure path.
- The Swift code uses `Sendable`, `Codable`, `Equatable`, preconditions, and
  structured concurrency consistently.
- Test fixtures are self-verifying (SHA-256 checked at load time).
- The live preview throttle handles clock resets correctly.
- JPEG decoding tolerance is documented and quantified (max diff ≤ 10, mean ≤ 2
  on 8-bit scale) — the right approach for inherently lossy decoders.

**Issues found and lessons learned:**
1. `ProcessingParameters` is missing several user-facing fields present in
   Python's `processing_parameters` tuple: `darkThreshold`, `lightThreshold`,
   `baseDetect`, `baseRGB`, `reject`. These are needed before the crop/colour
   pipeline can function.

2. The `FilmType` enum maps correctly to integer values 0-3 via `Int` raw
   representation, but the Python code also defines a `crop_only` path that
   skips all processing. This is correctly represented as `.cropOnly`.

3. `UInt16Image.rotated()` uses inclusive remapping loops. For 6K×4K images at
   3 channels, rotation is ~72 million loop iterations. This is acceptable for
   a correctness-first helper but will need a `vImage` replacement in Phase 2
   for production preview use (the Python code uses `cv2.rotate` which is
   SIMD-accelerated).

4. `makePreviewCGImage()` allocates a new `[UInt8]` array via per-pixel
   appending. At 6K×4K, this is ~72 MB. Using `UnsafeMutablePointer` +
   `CGDataProvider` with a release callback would eliminate the copy.

5. The app shell's `loadSelection()` method cancels the previous task but does
   not handle the case where `selection` changes during decoding (the decoded
   image would be discarded by the `guard self.selection == selection` check,
   which is correct).

6. The camera controller exposes `invertNegative`, `exposure`, and `saturation`
   as `@Published` but the setter methods don't call `objectWillChange.send()`
   on the main actor — they rely on `@Published` auto-synthesis which should
   work, but the `settingsLock.withLock` in the setter updates `settings` (a
   private struct) separately from the `@Published` property update. This
   creates a brief window where the published property has been updated but the
   private `settings` struct has not. Not a correctness bug for the prototype,
   but should be tightened.

7. The `UInt16Image.pixels` array exposure is `[UInt16]` — a value type that
   uses copy-on-write, but the `public private(set)` accessor allows external
   mutation via `image.pixels[index] = value`. Consider making `pixels` fully
   private with a read-only accessor for the processing pipeline.

8. **Float32 precision is pervasive in the Python pipeline.** `cv2.boxPoints`
   returns float32 values, and `matplotlib.colors.rgb_to_hsv` operates in
   float32 internally. Any Swift implementation using `Double` (float64) for
   equivalent computations must either match precision via `Float` casts (as
   done in `shrink_box` and `sat_adjust`) or accept documented tolerance. This
   is a recurring pattern that affects all stages downstream of OpenCV and
   matplotlib.

9. **The Python `shrink_box` has a benign `np.where` bug.** The code
   `np.where(box==topleft)[0][0]` finds the first row where *any* element
   matches topleft (element-wise comparison), rather than the row where *all*
   elements match. The net effect is benign because the `np.roll(box, -idx)`
   and `np.roll(new_box, idx)` operations cancel out, preserving the original
   point ordering. The Swift implementation replicates this exact behavior.

---

## 5. Project-Specific Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| `findContours` + `minAreaRect` pixel divergence | High | Use OpenCV C++ interop for initial port (matches Python byte-for-byte) |
| Telea FMM inpainting divergence | High | Use OpenCV C++ interop for initial port |
| `warpPerspective` divergence at boundary pixels | Medium | Test at 0-359° in 1° increments; document any ±1 LSB tolerance |
| Full-res decode 19.7% slower than RawPy | Medium | Eliminate double-copy via single-allocation bridge path |
| Live camera not exposed by DSLR as AVFoundation device | Medium | Already documented; vendor SDKs / tethering adapters are the expected path |
| CI cannot run RAF corpus tests (files outside repo) | Low | Tests gracefully skip; local verification via committed SHA-256 hashes |
| OpenCV adding non-trivial build complexity | Low | Homebrew `opencv` formula is stable; only 2 functions need interop |

---

## 6. Estimated Effort

| Phase | Work | Estimate |
|-------|------|----------|
| 1.2 Threshold | ~~vImage port, failing test~~ Done | ~~1-2 days~~ Complete |
| 1.5 WB | ~~vDSP vector ops~~ Done | ~~1 day~~ Complete |
| 1.7 Saturation | ~~HSV math~~ Done | ~~1 day~~ Complete |
| 1.2 Contours | OpenCV interop setup + binding | 1-2 days |
| 1.3 Perspective warp | DLT + Metal warp kernel | 2-3 days |
| 1.4 Histogram EQ | vDSP sort + percentile + caching | 2-3 days |
| 1.6 Exposure | vDSP vector ops + polynomials | 1-2 days |
| 1.8 Dust detection | vImage morphology + OpenCV contours | 1-2 days |
| 1.9 Dust inpainting | OpenCV inpaint binding | 1 day |
| 1.10 Caching | Hashable signatures | 1 day |
| 1.11 Batch export | OperationQueue + memory-aware parallelism | 2-3 days |
| Phase 2 Metal | 4 compute kernels | 1-2 weeks |
| Phase 3 SwiftUI app | Full inspector + preview + export UI | 2-4 weeks |
| Phase 4 Polish | Packaging + perf gates + snapshot tests | 1-2 weeks |

Total remaining: approximately **6-12 weeks** to a production-ready native
application, assuming one full-time developer. Four pipeline stages are now
complete. The widest variance remains in Phase 3 (UI), which can be
parallelised with engine work since the engine is testable independently.

---

## 7. Summary

The Swift port has a **solid, well-architected foundation** and is making
steady progress through the processing pipeline. The C bridge, image decoding,
buffer types, test infrastructure (now with float64 NPY support), CI, and
benchmark tooling are all production-quality. Four key pipeline stages are
complete and verified:

- **Threshold generation:** Exact pixel equality, pure Swift arithmetic
- **White balance:** Exact float64 equality, simple coefficient multiplication
- **Saturation:** ≤1 LSB documented tolerance, Float32-precision HSV conversion
- **Exposure:** Exact Float32-rounding equivalence across all adjustment paths

The project's development discipline — failing test before implementation,
exact pixel equivalence, documented tolerances only when unavoidable — is the
right approach for a correctness-critical image pipeline. Two important
learnings have emerged: float32 precision is pervasive in the Python pipeline
(cv2.boxPoints, matplotlib HSV), and Python's `np.where` element-wise matching
creates a benign bug in `shrink_box` that must be replicated for pixel
equivalence.

The remaining work is clearly scoped: histogram equalisation (percentile
computation), contour detection + perspective warp (requiring OpenCV C++
interop), dust
detection/inpainting, caching, batch export, and the full SwiftUI application.
The highest-risk items (contour detection and FMM inpainting) have a clear,
pragmatic mitigation: use OpenCV C++ interop for both, then optionally replace
with Metal in Phase 2 for performance.

The current full-resolution RAW decode being ~19.7% slower than RawPy is the
only measurable performance gap, with a known, low-risk fix (eliminate the
double buffer copy).
