# macOS Native App Roadmap

**Goal:** Rewrite Film Scan Converter as a native macOS application (Swift +
SwiftUI) with pixel-identical output for shared Python behavior, deterministic
tested output for new native grading features, better performance, and a modern
Cocoa UI.

> **Status:** This is the detailed technical design reference. The authoritative
> current step, verified progress, limitations, and next work are maintained in
> [Native macOS Development](../development/native-macos.md).
> The Swift application is the primary product and the only destination for new
> functionality. Python is maintenance-only legacy code until the
> [retirement gates](../legacy-python.md) are complete.

## Current Position

The interactive still-preview foundation, histogram equalisation, curves,
three-way color wheels, RawTherapee-compatible startup inversion, automatic
film-kind classification, and export are complete. The current product priority
is the film-specific camera-scan track: manual region wiring or automatic
rebate estimation, then base density + color-space conversion and flat-field
calibration. Contour/crop detection, perspective warp, and dust handling remain
later replacement gates.

The TIFF/JPEG/PNG/DNG export contract is implemented with individual and
batch-all workflows, cancellation, partial-file cleanup, and 19 focused
format/manager tests. The app-level Export All path intentionally uses lazy
sequential decode/classify/process/write for unloaded batch files so large
import lists do not require all full-resolution decodes to remain resident.
`ExportManager.exportBatch()` remains available for callers that already hold
a bounded prebuilt request set.
The native app can export processed full-resolution images with applied
corrections, frame, and aspect ratio.

Completed foundations:

- Swift Package Manager `FilmScanEngine` library and `FilmScanConverterMac` app.
- Frozen Python-generated fixtures consumed by exact-pixel Swift tests.
- Pixel-equivalent rotate, flip, frame, and aspect-ratio helpers.
- Native standard-image decoding and a thread-safe LibRaw bridge with exact
  RawPy-equivalent representative RAF proxy and full-resolution outputs.
- Threshold generation: `get_threshold` with exact pixel equality for 5
  dark/light parameter combinations, covering `convertScaleAbs` (16→8 bit),
  BGR-to-grayscale (OpenCV fixed-point coefficients), `inRange` binary
  thresholding, and 7×7 binary erosion (2 iterations).
- `shrink_box` coordinate math matching Python float32 precision.
- Float64 NPY fixture loading for intermediate floating-point pipeline stages.
- White balance (`wb_adjust_coeff`) with exact float64 equality for 4
  temp/tint settings.
- Saturation adjustment (`sat_adjust`) via RGB↔HSV conversion with documented
  ≤1 LSB tolerance for 5 saturation levels.
- Exposure adjustment with exact Python float32-rounding equivalence for 5
  parameter combinations.
- Histogram equalisation with exact float64 equality for the current
  three-fixture corpus.
- Authoritative overall/per-channel curves and highlight/midtone/shadow color
  wheels with matching GPU preview behavior.
- Deterministic startup classification for color negative, B&W negative, and
  slide scans, applying the matching RawTherapee film-negative preset when
  appropriate.
- Main-window file drag and drop plus per-file correction controls.
- A reusable 16-bit Core Image/Metal still-preview renderer with live bindings
  and bounded latest-value-wins scheduling. The production renderer is verified
  against the CPU path across 2,655 comparisons with a maximum difference of
  2/255.
- Optional AVFoundation/Core Image live camera preview prototype.
- macOS CI that tests the engine and builds the app.
- TIFF/JPEG/PNG/DNG export with CGImageDestination for TIFF/JPEG/PNG and a
  custom minimal DNG writer producing valid TIFF containers with DNG IFD tags.
  Actor-based ExportManager with sequential and parallel modes, cancellation,
  per-file error reporting, and partial-file cleanup. The SwiftUI app's Export
  All path performs lazy sequential per-file decode/classify/process/write for
  unloaded files to keep batch memory bounded. Export inspector section with format
  options, frame, aspect ratio, destination folder picker, progress, and error
  display. 19 focused export tests plus app-level integration coverage.

The immediate goal is to continue the film-specific camera-scan track from
startup classification, engine-only manual rebate base measurement/roll reuse
(Slice C), and initial engine-only automatic rebate candidates (Slice D) toward
manual/automatic UI region selection or density-to-display rendering. Nothing
later in this roadmap should be interpreted as implemented unless the status
page says it is.

A parallel film-specific processing track has started from the
[camera-scan film-processing research brief](../film-processing-research.md).
Slices A (capture normalization), B (linear-capture diagnostics), and the first
engine-only C API (manual rebate base measurement, roll profile storage, and
base-density precedence resolution) are complete as standalone engine APIs. The
first engine-only Slice D API returns deterministic edge rebate candidates with
measured base density and confidence. Startup film-kind classification is
connected to preview and export; the density-domain Slice A/C/D APIs are not yet
connected to preview or export.

### Native Export Contract — Complete

1. ~~Define format-specific bit-depth, orientation, color-profile, source
   metadata, and processing-metadata behavior.~~
2. ~~Implement TIFF, JPEG, and PNG export with round-trip tests.~~
3. ~~Define and validate processed, demosaiced 16-bit RGB DNG output without
   claiming untouched sensor RAW semantics.~~
4. ~~Add cancellation, collision, partial-file cleanup, and reproducibility
   tests.~~
5. ~~Add memory-bounded batch export and deterministic progress/error reporting.~~

### Next Implementation Step: Manual Region UI Or Automatic Rebate Estimation

Direct Metal-backed display and idle authoritative rendering remain deferred
Stage 4 preview work.

---

## Phase 0: Test Harness — Pixel-Equivalence Gate

Every macOS rewrite commit must pass against a frozen reference corpus. No pixel may differ beyond documented tolerance.

### 0.1 Snapshot Corpus

Generate a locked set of intermediate and final outputs from the Python app:

| Snapshot type | What | Count |
|---|---|---|
| Synthetic images | `np.random.default_rng(0).integers(0, 65536, size=(H, W, 3), dtype=np.uint16)` at 4 resolutions (240×360, 2000×3000, 4000×6000, 8000×12000) | 4 images |
| Real RAW corpus | 5 RAF files from `sample-raw/` (DSCF0669, DSCF0718, DSCF0729, DSCF2417, DSCF2422) | 5 images |
| Intermediate stages | RAW (after RawPy decode + black border trim), threshold, contour image, histogram, histogram EQ result, exposure result, WB result, final export | ~8 per image |
| Parameter grid | Each parameter varied across its full range at representative points | ~200 variants |

### 0.2 Snapshot Format

Save as 16-bit PNG or uncompressed NPY with an accompanying JSON metadata file containing:
- Input image hash (SHA-256)
- Full parameter set (all `processing_parameters` + `class_parameters`)
- Pipeline stage name
- Output image hash (SHA-256 of raw bytes)
- Rendering time (wall clock, milliseconds)

### 0.3 Test Harness Architecture

```
Swift Test Target (XCTest)
├── FixtureLoader
│   ├── loads .npy / .png input
│   ├── loads expected_output.npy
│   └── loads metadata.json
├── PipelineVerifier
│   └── for each stage:
│         input → Swift implementation → output
│         assert output ≈ expected (exact bit match or ≤1 LSB tolerance)
│         assert render_time ≤ 2× Python baseline
└── RegressionGate (CI blocking step)
    └── must pass before any macOS-native merge
```

### 0.4 Pixel-Equality Policy

- **First pass:** Exact bit-for-bit equality (`UInt16` arrays)
- **Where floating-point accumulates differently (e.g. `pow`, `divide`):** Tolerance of ≤1 LSB in 16-bit (`±1` in `UInt16` range) with per-stage documented waivers
- **OpenCV operations (`warpPerspective`, `inpaint`, `threshold`):** Must match exactly — these are deterministic algorithms with well-defined behaviour. Note that `inpaint` (Telea FMM) is numerically sensitive; start with OpenCV interop for correctness.
- **Histogram equalisation:** Exact match for percentile-based calculations; OK to differ at floating-point accumulation edges only (document each waiver). The Python code uses `np.percentile` with linear interpolation; replicate exactly.
- **Native-only grading features:** Define the authoritative CPU math first,
  freeze identity and parameter-grid fixtures, then require the GPU preview to
  stay within a documented tolerance.

### 0.5 Performance Baseline

Record minimum/median times for each pipeline stage on the reference corpus running Python. The Swift version must match or exceed these before any feature work begins.

**Core processing pipeline stages** (called within `process()`):

- `get_threshold` — crop detection (grayscale + threshold + erode)
- `find_optimal_crop` — contour extraction + minAreaRect
- `crop` — perspective warp with homography
- `hist_EQ` — percentile-based histogram equalization
- `wb_adjust_coeff` — coefficient-based white balance
- `exposure` — gamma + shadows + highlights
- `sat_adjust` — RGB→HSV→multiply saturation→HSV→RGB
- `find_dust` — threshold + dilate/erode + contour area filter
- `fill_dust` — per-channel Telea FMM inpainting

**Display/output stages** (called within `get_IMG()`, not part of core processing):

- `draw_histogram` — per-channel histogram visualization
- `add_frame` — white border + aspect ratio pad

Benchmark full pipeline cold (no caches) and warm (cached crop + histogram stats + dust mask).

### 0.6 Coverage Audit And Test Priorities

Coverage is a diagnostic, not the acceptance criterion. Pixel equivalence,
known-value math, failure behavior, and workflow contracts matter more than a
raw percentage. Still, every new engine slice should measure coverage so
untested branches are understood rather than accidental.

Current full-suite coverage snapshot from 2026-06-16:

| Scope | Line coverage | Interpretation |
|---|---:|---|
| `FilmScanEngine` sources | 85.8% | Solid engine baseline after RAW direct decode, export, and thumbnail work; remaining gaps include logging, platform/error branches, optional-output fallbacks, and older processing paths. |
| All included native targets | 55.6% | App/view code is intentionally much less covered than engine code; app workflow tests should be prioritized over broad view-line coverage. |
| `FilmNegativeProcessing.swift` | 92.3% | Normal math paths are well covered; remaining gaps are mostly validation traps and rare fallback branches. |
| `CaptureDiagnostics.swift` | 98.9% | All normal paths covered. The single uncovered line is the bit-depth `precondition` trap. |

Use the full native suite to regenerate coverage:

```sh
swift test --package-path native/FilmScanEngine --enable-code-coverage
xcrun llvm-cov report \
  native/FilmScanEngine/.build/arm64-apple-macosx/debug/FilmScanEnginePackageTests.xctest/Contents/MacOS/FilmScanEnginePackageTests \
  -instr-profile=native/FilmScanEngine/.build/arm64-apple-macosx/debug/codecov/default.profdata \
  native/FilmScanEngine/Sources/FilmScanEngine
```

Prioritize new tests in this order:

1. Data-loss, cancellation, invalid-input, and partial-output behavior.
2. Pixel/numerical contracts at boundaries and across composed stages.
3. BGR ordering, bit-depth, metadata, and serialization contracts.
4. Real representative files and held-out calibration data.
5. Previously unexplained uncovered branches.

Do not add tests solely to execute trivial getters or deliberate process-
terminating `precondition` branches. If a trap can be reached by user input,
change it to a typed error and test the recoverable behavior.

---

## Phase 1: Image Processing Engine — Swift Port

Port `RawProcessing.py` (769 lines) to pure Swift, with zero UI. Deliverable: a Swift Package Manager library `FilmScanEngine`.

### 1.1 RAW Decoding

| Python | Swift replacement |
|---|---|
| `rawpy.imread` + `raw.postprocess` | LibRaw (C library, manual Swift bindings via module map) or `RAWKit` |
| Half-size proxy (`half_size=True`) | LibRaw's built-in half-size output (`imgdata.sizes.iwidth/2`, `imgdata.sizes.iheight/2`) |

**Dependencies:** LibRaw (via XCFramework or Homebrew + bridging header). Must use identical demosaic algorithm, gamma curve, white balance multipliers, and output colour space as RawPy's default `postprocess` call.

**Fallback path:** `cv2.imread` for non-RAW → `CGImageSource` + `vImage` for TIFF/JPEG/PNG.

**Black border trim:** Port `findContours` logic for the initial mask-based crop. Python uses `cv2.threshold(src, 0, 65535, cv2.THRESH_BINARY)` to find non-zero rows/cols and crops to the bounding rectangle. This must produce identical crop bounds.

### 1.2 Threshold & Crop Detection

| Python (OpenCV) | Swift replacement |
|---|---|
| `cv2.convertScaleAbs(img, alpha=255/65535)` | `vImageConvert_16UTo8U` (Accelerate) with scale factor |
| `cv2.cvtColor(BGR2GRAY)` | Custom weighted sum: `0.114*B + 0.587*G + 0.299*R` via `vDSP` or manual loop |
| `cv2.inRange()` | `vImage` lookup table or manual threshold sweep |
| `cv2.erode(kernel=(7,7), iterations=2)` | `vImageErode_Planar8` with a 7×7 kernel, applied twice |
| `cv2.findContours(mode=RETR_EXTERNAL, method=CHAIN_APPROX_SIMPLE)` | Custom boundary-following (Suzuki-Abe algorithm) or `Vision` framework `VNDetectContoursRequest`. **Warning:** Vision returns a different contour format than OpenCV; pixel-identical results require a manual Suzuki-Abe implementation. |
| `cv2.minAreaRect()` | Rotating calipers algorithm over convex hull |
| `cv2.boxPoints()` | Manual trig from (center, size, angle) to 4 corner points |

**Key requirement:** `findContours` + `minAreaRect` must return the exact same rectangle as OpenCV. This is the most likely divergence point. Lock with a dedicated test suite over all corpus images and all rotation angles (0–359° in 1° increments).

### 1.3 Perspective Warp (Crop)

| Python (OpenCV) | Swift replacement |
|---|---|
| `cv2.getPerspectiveTransform(src, dst)` | Solve 3×3 homography via DLT (direct linear transform) using SVD. Four point correspondences → 8 equations → solve `Ah = 0`. |
| `cv2.warpPerspective()` | `vImageWarpPerspective_ARGB8888` / `vImageWarpPerspective_Planar8` (Accelerate) for 8-bit; custom Metal compute shader for 16-bit with bilinear interpolation |

Must match OpenCV's `WARP_INVERSE_MAP` behaviour and interpolation (`INTER_LINEAR`). Test at rotation angles 0–359°.

### 1.4 Histogram Equalization

| Python | Swift replacement |
|---|---|
| `np.percentile(sample, pct, axis=(0,1))` | Full sort + linear interpolation — `vDSP` sort each channel, then pick the nearest/between values at the percentile positions |
| `np.divide(... out=..., where=...)` | `vDSP.divide` with zero guard (check divisor ≠ 0 before calling) |
| `np.multiply(img, white_multipliers)` | `vDSP.multiply` |
| Base colour detection | Same percentile logic, same `base_detect` modes (Percentile, Manual, WB Picker) |

Must replicate the exact `np.percentile` linear interpolation behaviour between sorted adjacent values. Use the same casing strategy for `base_rgb` / `film_type`.

### 1.5 White Balance

`wb_adjust_coeff` — 3-element coefficient vector:
- `[1-t/T+t/T/2, 1-t/T, 1+t/T+t/T/2]` where `T = 200`, `t` is integer slider value
- `vDSP.multiply(coefficients, img)` per channel

White balance picker: compute mean over masked pixels → sum of pixel values divided by mask pixel count. Port `cv2.mean(cropped_image, mask)` directly.

### 1.6 Exposure

| Python | Swift replacement |
|---|---|
| `np.clip(img, 0, 65535)` | `vDSP.clip` |
| `img /= 65535` | `vDSP.divide` by 65535.0 |
| `np.power(img, 2^(-gamma/100))` | `vvpowf` (Accelerate) — vector power for single-precision floats. The exponent `2^(-gamma/100)` maps the gamma slider to a power curve. |
| Shadows: `coeff * min(img-0.75,0)^2 * img` | `vDSP` vector ops: threshold subtraction, square, multiply |
| Highlights: `coeff * max(img-0.25,0)^2 * (1-img)` | `vDSP` vector ops |

The exact polynomial coefficients `4.15e-5` (shadows) and `0.02185` (highlights) are empirically tuned. Preserve exactly.

### 1.7 Saturation

| Python | Swift replacement |
|---|---|
| `matplotlib.colors.rgb_to_hsv(img)` | Direct math: `V = max(R,G,B)`, `S = (V-min)/(V+ε)`, hue from standard formula |
| `img[:,:,1] *= sat_adjust` | Multiply S channel, clip to [0, 1] |
| `matplotlib.colors.hsv_to_rgb(img)` | Inverse HSV → RGB standard formulas |

Avoid importing a colour science library — this is a ~20-line pure math function. Write it inline with per-pixel loops.

### 1.8 Dust Detection & Inpainting

| Python | Swift replacement |
|---|---|
| `cv2.threshold()` | Accelerate lookup table |
| `cv2.dilate` / `cv2.erode` | `vImageDilate_Planar8` / `vImageErode_Planar8` |
| `cv2.findContours` (filter by area) | Same as Phase 1.2; filter by area after extraction |
| `cv2.drawContours(..., FILLED)` | Custom fill via flood-fill or Core Graphics |
| `cv2.inpaint(INPAINT_TELEA, radius=3)` | Telea's FMM inpainting. Applied **per-channel** (channels split, inpainted separately, merged). |

`cv2.inpaint` (Telea method) is the hardest function to port exactly. The Python code splits channels and inpaints each independently with radius=3. Options:

1. **Call OpenCV via C++ interop** (safest for pixel-equivalence) — requires a C++ bridging header + module map + linking `libopencv_imgproc`. Adds OpenCV as a dependency but guarantees bit-identical output.
2. **Port Telea FMM to Metal** (best performance) — compute shader implementation of the fast marching method. Multiple passes with distance map propagation. Significant implementation effort (~500+ lines of Metal shader code).
3. **Replace with simpler algorithm** (breaks pixel-equivalence) — e.g. median blur over masked regions. Only acceptable if the reference corpus is regenerated.

**Recommendation:** Start with Option 1 (OpenCV interop) for correctness, then pursue Option 2 (Metal) as a performance optimization in Phase 2.

### 1.9 Helper Functions

| Python | Swift replacement |
|---|---|
| `rotate(img, undo)` — rotation + flip | `vImageRotate90_*` / `vImageHorizontalReflect_*` for 90° rotations; bilinear interpolation for arbitrary angles |
| `add_frame(img)` — white border + aspect ratio pad | Create larger blank image, copy source into center, fill border with white (65535) |
| `draw_histogram` — per-channel histogram | Compute via `vImageHistogramCalculation_Planar8`, render as overlay bars on the image |
| `shrink_box` — coordinate math | Pure `CGPoint` / `CGSize` arithmetic |

### 1.10 Caching Strategy

Port the exact cache-invalidation scheme from `RawProcessing.py:126, 258–267, 447–460`:

- **`_raw_revision`** — incremented on each `load()` call (line 126). Increments even if the same file is reloaded, so all downstream caches invalidate.
- **`_dust_signature`** — tuple of `(_raw_revision, img.shape, rect, border_crop, tuple(ignore_border), dust_threshold, max_dust_area, dust_iter)`. Checked before calling `find_dust()`; if it matches the stored signature, the cached `dust_mask` is reused.
- **`_histogram_stats_signature`** — tuple of `(_raw_revision, img.shape, rect, border_crop, film_type, base_detect, tuple(base_rgb), tuple(ignore_border), ignore_neg_border, black_point_percentile, white_point_percentile, black_point)`. Checked before calling the expensive `np.percentile` computation; if it matches, cached `black_offsets` and `white_point` are reused.

Swift implementation: structs conforming to `Hashable` for each signature type.

### 1.11 Multiprocessing Export

The Python version in `source/GUI.py:1063–1095` uses `multiprocessing.Pool` with serialised `RawProcessing` objects. The `__getstate__` method (line 709) excludes large numpy arrays from pickle serialization via the `memory_attributes` tuple (`'IMG', 'thresh', 'RAW_IMG', 'proxy_RAW_IMG', 'dust_mask', '_dust_signature', '_histogram_stats_signature', '_histogram_black_offsets', '_histogram_white_point'`). Workers reload the source file, decode RAW, and reprocess.

Swift replacement:
- `OperationQueue` with `maxConcurrentOperationCount` determined by a memory-aware heuristic
- Use `os_proc_available_memory()` plus `NSProcessInfo.processInfo.physicalMemory` to calculate safe parallelism
- Each export operation: load RAW → decode → process → write to disk
- Cancellation via `Operation.cancel` + checking `isCancelled` between stages
- Clean up partial output files on cancellation

### 1.12 Advanced Grading: Curves And Three-Way Color Wheels

Add authoritative, deterministic grading stages after base inversion, white
balance, histogram equalisation, and exposure, but before final output framing.

**Curves:**

- One overall RGB curve plus independent red, green, and blue curves.
- Store normalized control points in `ProcessingParameters`.
- Define endpoint behavior, control-point ordering, interpolation, and clipping
  explicitly. Start with a monotonic piecewise-cubic or piecewise-linear
  reference implementation; do not allow curve overshoot to change pixels
  unpredictably.
- Build 16-bit lookup tables for the authoritative CPU pipeline and matching
  GPU lookup textures for interactive preview.
- Add identity, channel-isolation, extreme-point, and parameter-grid fixtures.

**Three-way color wheels:**

- Separate highlight, midtone, and shadow color-balance controls.
- Define each wheel as a neutral-centered chroma vector plus strength, with
  documented luminance masks and overlap behavior.
- Preserve neutral luminance unless the user explicitly changes luminance.
- Require identity at zero and bounded GPU-versus-CPU differences across the
  representative corpus.

These controls must exist in both the authoritative pipeline and the
interactive preview. UI-only approximations are not acceptable for export.

### 1.13 Export Formats, Including DNG — Complete

TIFF, JPEG, PNG, and DNG output is implemented behind one tested export
contract.

- ~~Preserve orientation, dimensions, bit depth, color profile, source
  metadata, and processing metadata where the selected format supports them.~~
  TIFF and PNG use 16-bit deep export; JPEG is 8-bit with configurable quality.
- ~~Define DNG scope before implementation. The initial target is a processed,
  demosaiced 16-bit RGB DNG with explicit color/profile metadata, not a
  reconstruction of the camera's original sensor mosaic.~~
  Minimal DNG writer produces valid little-endian TIFF container with IFD and
  SubIFD holding DNG version, unique camera model, and processed-RGB label tags.
- ~~Never label processed RGB DNG output as untouched camera RAW.~~
  DNGImageDescription tag explicitly states "Processed RGB from camera film scan".
- ~~Validate DNG output with multiple readers and require round-trip pixel,
  metadata, and orientation tests.~~
  DNG byte-order and minimum-size checks; extended multi-reader validation
  deferred.
- ~~Add individual and memory-bounded batch export, cancellation, partial-file
  cleanup, collision handling, and reproducible output tests.~~
  ExportManager actor with sequential `export()` and parallel `exportBatch()`
  modes, memory-bounded concurrency heuristic, `Task.isCancelled` checking at
  each request boundary, `ExportManagerError.cancelled` for remaining items,
  and per-file error cleanup via `FileManager.removeItem`. The app-level Export
  All workflow uses sequential lazy requests to preserve bounded memory.
  19 focused tests in `ExportTests`.

### 1.14 Film-Specific Camera-Scan Processing Track

Camera scans must be treated as measurements from a combined camera, lens,
backlight, RAW-conversion, and film-stock system. This track replaces simple
RGB inversion incrementally without making the current preview/export pipeline
depend on unfinished calibration behavior.

#### Developer Orientation

The research describes the desired physical pipeline:

```text
decoded linear capture + matched flat field
  -> relative transmittance
  -> optical density
  -> base-density subtraction
  -> density correction / inverse film curve
  -> scene-linear positive
  -> display rendering
```

Do not replace `correctedPreview`'s current simple inversion in one change.
Build and verify each stage as an independent authoritative CPU API first. Wire
it into preview and export only after the required inputs, fallback behavior,
and numerical contracts are defined.

Current code locations:

- `Sources/FilmScanEngine/FilmNegativeProcessing.swift`: authoritative
  capture-normalization and density primitives.
- `Tests/FilmScanEngineTests/FilmNegativeProcessingTests.swift`: focused
  behavior and numerical-contract tests.
- `docs/film-processing-research.md`: physical rationale, formulas, profile
  architecture, and longer-term calibration approach.

Current data conventions:

- Engine pixel buffers are interleaved **BGR**, not RGB.
- `UInt16Image` is the decoded capture representation.
- Transmittance and density stages currently return interleaved `[Double]`
  values in BGR order.
- A matched flat field must have identical dimensions and channels to the
  capture.
- Transmittance is clamped to `[epsilon, 1]`; density is therefore finite and
  nonnegative.
- Base-density subtraction clamps each channel to zero.
- The current APIs use `precondition` for programmer errors. User-supplied
  invalid files must be validated before calling them and reported as normal
  application errors.

#### How To Implement A Slice

For every slice in this track:

1. Define the input/output types and BGR/linear-light conventions.
2. Add identity, boundary, and known-value tests before integration.
3. Implement the authoritative CPU behavior in `FilmScanEngine`.
4. Add a composed-stage test proving it connects correctly to the prior slice.
5. Measure focused source coverage and explain any intentionally uncovered
   validation traps.
6. Add preview/GPU behavior only after the CPU contract is stable.
7. Update this section and `docs/development/native-macos.md` without claiming
   later stages are complete.

Run the focused and full gates:

```sh
swift test --package-path native/FilmScanEngine \
  --filter FilmNegativeProcessingTests
swift test --package-path native/FilmScanEngine
swift build --package-path native/FilmScanEngine \
  --product FilmScanConverterMac
```

For focused coverage:

```sh
swift test --package-path native/FilmScanEngine \
  --enable-code-coverage --filter FilmNegativeProcessingTests
xcrun llvm-cov report \
  native/FilmScanEngine/.build/arm64-apple-macosx/debug/FilmScanEnginePackageTests.xctest/Contents/MacOS/FilmScanEnginePackageTests \
  -instr-profile=native/FilmScanEngine/.build/arm64-apple-macosx/debug/codecov/default.profdata \
  native/FilmScanEngine/Sources/FilmScanEngine/FilmNegativeProcessing.swift
```

The current focused suite covers 92.1% of source lines. Its uncovered lines are
the deliberate `precondition` failure branches; executing those in-process
would terminate the test runner. If these validations become reachable from
user input, replace the relevant traps with typed errors and test them.

#### Delivery Slices

| Slice | Status | Deliverable | Required tests and done criteria |
|---|---|---|---|
| A. Capture normalization foundation | Complete as standalone engine API | Per-channel black-level correction, matched flat-field normalization, safe transmittance clamping, optical-density conversion, and manual base-density subtraction. | Known ratios, BGR ordering, defaults, spatial flat-field correction, clipping/bounds, matched-exposure invariance, density-ratio identity, Codable parameters, and composed pipeline. Focused suite: 11 tests, 92.1% line coverage; only precondition traps uncovered. |
| B. Linear-capture diagnostics | Complete as standalone engine API | Per-channel minimum/maximum values, low/high clipping fractions (threshold-based with 0.1% warning floor), source-kind and bit-depth metadata, and deterministic warnings for 8-bit input, lossy source, clipped channels, missing flat field, and explicitly marked nonlinear input. Not yet wired to the SwiftUI import workflow. Focused suite: 18 tests, 98.9% line coverage; only the bit-depth precondition trap uncovered. | Synthetic 8/16-bit cases, channel-specific clipping, deterministic warning rules, Codable report, and no false nonlinear warning for known linear fixtures. |
| C. Manual base selection and roll reuse | Complete as standalone engine API | Compute robust median/trimmed-mean transmittance and density from a user-selected rebate rectangle; persist and reuse it in a roll profile. | Dust/outlier resistance, invalid/empty region errors, BGR correctness, five-frame roll stability, serialization, and explicit precedence rules. Focused suite: 17 film-negative processing tests. UI region picking remains deferred. |
| C1. Startup film-kind classification | Complete in engine and app | Classify new imports as color negative, B&W negative, or slide and initialize the matching RawTherapee preset without overwriting existing per-file settings. | Synthetic orange-mask, low-chroma, and positive-slide cases; app export coverage proving unloaded files receive automatic settings during lazy batch export. |
| D. Automatic rebate estimation | Initial engine API complete | Detect edge candidate rebate regions and return base density plus confidence; never silently override a stronger roll/frame base. UI selection and overlay geometry remain deferred. | Synthetic top/left border fixtures, borderless rejection, and explicit precedence below measured roll/frame base. Remaining coverage: rotated frames, dust contamination, and deterministic overlay geometry. |
| E. Generic C-41 scene estimate | Complete as standalone engine API | Per-channel density slopes/offsets producing scene-linear positive values via `genericC41SceneEstimate()`, exposure normalization via median-green reciprocal (`normalizeSceneExposure()`), and a composed `densityToSceneLinear()` pipeline. | Identity/default profile, monotonicity, channel isolation, extreme density bounds, JSON round-trip, and composed pipeline tests. Focused suite adds 9 tests; all density-domain slices now link into one end-to-end density-to-scene path. |
| F. Shared display renderer and noise protection | Planned | Stable exposure, white balance, tone map, and bounded noise-safe highlight/shadow behavior. | Neutral identity, monotonic tone curve, finite output, highlight rolloff, noise-gain limiting, and CPU/GPU tolerance before UI integration. |
| G. Capture, stock, and roll profiles | Planned | Separate Codable profile types and precedence rules for capture setup, film stock, and roll-specific corrections. | Schema/version migration, missing-profile fallback, precedence, round-trip serialization, and proof that changing capture profile does not mutate stock curves. |
| H. Per-stock curves and calibrated matrices | Planned | Monotonic inverse-density LUTs and fitted density/display matrices, initially for Portra 400, Portra 160, Ektar 100, and Gold 200. | LUT monotonicity, interpolation boundaries, held-out validation reports, matrix regularization bounds, and no regression to generic C-41 fallback. |
| I. Optional residual 3D LUTs | Planned last | Blendable residual LUT after the physical pipeline is stable. | Identity LUT, interpolation boundaries, strength endpoints, held-out improvement, overfit rejection, and deterministic CPU/GPU agreement. |

#### Completed Ticket: Manual Base Selection And Roll Reuse (Slice C)

This ticket was kept engine-only and small enough to review independently:

1. `measureBaseDensity(image:flatField:region:)` accepts a `UInt16Image`, matched
   flat field, and coordinate rectangle identifying the rebate area.
2. It computes robust median and trimmed-mean transmittance from the selected
   region and returns per-channel base density in BGR order.
3. It returns a confidence score based on median-vs-trimmed-mean agreement and
   explicit outlier rejection.
4. `RollProfile` stores film-stock ID, capture-profile ID, measured base
   density, exposure bias, white-balance correction, and measurement count.
5. `resolveBaseDensity` implements precedence rules: measured roll base >
   measured frame base > stock + capture default > manual picker.
6. Roll profiles persist and reload via Codable serialization.
7. Synthetic tests cover invalid/empty regions, dust contamination resistance,
   five-frame roll stability, serialization round-trips, BGR correctness, and
   precedence.

Remaining out of scope: manual UI region picking, automatic rebate UI selection
and overlay geometry, film-stock profiles, generic C-41 rendering, GPU kernels,
and replacing the current preview inversion.

#### Completed Ticket: Initial Automatic Rebate Candidates (Slice D)

This first Slice D ticket is engine-only:

1. `automaticRebateCandidates(image:flatField:)` evaluates deterministic top,
   bottom, left, and right edge strips.
2. Each retained candidate includes its `ImageRegion`, measured base density,
   and confidence.
3. Borderless frames are rejected by requiring the candidate transmittance to
   separate from the interior.
4. `resolveBaseDensity` accepts automatic base density below measured roll and
   measured frame data, preserving stronger manual measurements.
5. Synthetic tests cover top-border detection, vertical edge detection,
   borderless rejection, and precedence.

Remaining out of scope: UI selection, overlay geometry, rotated-frame candidate
search, dust-contaminated confidence tests, generic C-41 rendering, GPU kernels,
and replacing the current preview inversion.

#### Next Recommended Ticket: Manual/Automatic Region UI Or Density Rendering

Choose one narrow follow-up:

1. Wire the completed Slice C engine API to a SwiftUI manual rebate rectangle
   picker, display measured density/confidence, and persist the selected roll
   profile;
2. expose the completed Slice D candidate list as selectable app overlay
   geometry without automatically overriding roll/frame measurements; or
3. start the generic C-41 density-to-display renderer with CPU contracts before
   adding preview acceleration.

The authoritative CPU implementation must define every stage first. Preview
GPU implementations may follow only after identity, parameter-grid, and
numerical behavior tests exist. Capture-profile and film-stock-profile data
must remain separate so changing a backlight does not change the underlying
stock curve.

---

## Phase 2: Rendering Pipeline — Metal / Accelerate

After the Swift port is pixel-identical, optimise the hot paths.

Real-file UX testing established one exception to that ordering: still-image
slider feedback must become real-time before the rest of the correction engine
is complete, otherwise the SwiftUI workflow cannot be evaluated meaningfully.
Use a fast, explicitly non-authoritative GPU preview while dragging and retain
the pixel-equivalent CPU path for idle verification and export. The staged
implementation and acceptance criteria are in the
[real-time still preview plan](../development/realtime-preview-plan.md).

### 2.1 Profiling Targets

Measure on 6000×4000 16-bit images. Hot paths will likely be:

| Stage | Est. % of pipeline time | Optimisation |
|---|---|---|
| RAW decode + RawPy postprocess | 40–60% | LibRaw `unpack()` + manual postprocess, skip unnecessary conversions |
| Perspective warp (crop) | 10–20% | Metal compute kernel with bilinear interpolation |
| `hist_EQ` percentile | 5–10% | `vDSP` sort + quantile; cache aggressively |
| Dust inpainting | 5–15% | Metal compute kernel (Telea FMM) |
| Saturation (HSV convert) | 3–8% | Fuse with exposure in a single kernel |

### 2.2 Metal Compute Pipeline

Write Metal kernels for the most expensive stages:

1. **`warpPerspective`** — Homography matrix as buffer, bilinear sampling with edge clamping. Target: 2–5× over `vImage`.

2. **`inpaint` (Telea FMM)** — Iterative PDE solver. Natural fit for compute shaders. Multiple passes with distance map propagation. Complex but large speedup potential over per-channel CPU loops.

3. **`histogram_equalization`** — One pass to build per-channel histograms via `atomic_uint`, one pass to apply the LUT. Use threadgroup memory for partial histograms to reduce global atomics.

4. **`exposure` + `wb_adjust` + `saturation` + advanced grading** — Fuse the
   per-pixel stages where practical. Curves should use lookup textures; color
   wheels should use the same documented tonal masks as the authoritative CPU
   pipeline. Reduce memory bandwidth without changing control meaning.

### 2.3 Memory Strategy

- Use `MTLBuffer` with `MTLStorageModeManaged` for CPU↔GPU transfers
- Stream RAW files: decode into a shared buffer, process in tiles if the image exceeds available GPU memory (rare for 6000×4000 at 16-bit = ~144 MB)
- Use `vImage` for operations that run faster on CPU (erode/dilate, threshold) — Accelerate is already highly optimised for these small-kernel morphology ops
- Plan the pipeline as GPU-only segments where possible to minimize CPU↔GPU round trips

### 2.4 Preemptive Throttling

Port the memory-aware processor allocation:
- Estimate per-photo memory: `RAW_IMG.nbytes * 4 * 12` (heuristic from Python code)
- For batch export: sum all photo estimates, cap by available system memory, bound by `os.cpu_count()` and `max_processors_override`
- Use `ProcessInfo.processInfo.physicalMemory` and `os_proc_available_memory()`
- For CPU-bound work: `DispatchQueue.concurrentPerform`. For GPU work: `MTLCommandQueue` with appropriate buffer tracking.

---

## Phase 3: SwiftUI Application

### 3.1 Architecture

```
FilmScanConverter.app
├── Model Layer (FilmScanEngine SPM package)
│   ├── ProcessingPipeline (ported from RawProcessing.py)
│   ├── Parameters (Codable, ObservableObject-compatible)
│   ├── ImageCache (NSCache with LRU eviction)
│   └── ExportManager (OperationQueue-based batch export)
├── View Model Layer
│   ├── DocumentModel (ObservableObject — owns all photo state)
│   ├── PhotoViewModel (per-photo parameters + processing)
│   ├── CropViewModel
│   ├── ColourViewModel
│   ├── BrightnessViewModel
│   ├── GradingViewModel
│   └── ExportViewModel
└── View Layer (SwiftUI)
    ├── ContentView (split pane: inspector | preview)
    ├── ImportPanel / PhotoList (with drag-to-reorder)
    ├── InspectorPanel (scrollable controls, collapsible sections)
    ├── PreviewView (NSViewRepresentable wrapping Metal-backed view)
    ├── CurveEditor / ThreeWayColorWheels
    ├── ExportSheet (progress + abort + error log)
    └── AdvancedSettingsSheet
```

### 3.2 Key UI Requirements (Feature Parity)

| Python/Tkinter | SwiftUI equivalent |
|---|---|
| `ttk.Combobox` for photo list | `Picker` + `List` with selection binding |
| `ScaleEntry` (slider + spinbox) | `Slider` + `TextField` bound to the same `@State` in `HStack` |
| `CheckLabel` | `Toggle` |
| `ComboLabel` | `Picker` with `.menu` style |
| Scrollable control panel | `ScrollView` with grouped `Form` sections |
| Image preview (PIL `ImageTk`) | `NSImageView` via `NSViewRepresentable`, zoom/pan via `NSScrollView` |
| Process view switcher | `Picker` with `.segmented` style |
| Tooltips | `.help()` modifier (native macOS tooltips) |
| Menubar (File, Edit) | `CommandMenu` / `CommandGroup` |
| Keyboard shortcuts | `.keyboardShortcut()` modifier |
| Progress bar | `ProgressView` |
| Modal dialogs | `.sheet()` / `.alert()` / `.confirmationDialog()` |
| Colour picker | `ColorPicker` |
| File open/save | `.fileImporter()` / `.fileExporter()` (native NSOpenPanel/NSSavePanel) |
| Export with progress | `ProgressView` in sheet with cancellation button |

### 3.3 Views to Port

1. **Split view:** Left inspector panel (scrollable, ~320pt), right preview area (flexible). Resizable divider.
2. **Inspector sections (collapsible):**
   - Photo selector + import/prev/next/remove buttons
   - Processing: film type picker, reject toggle, dust removal toggle, global sync toggle
   - Crop & rotate: dark/light threshold sliders, border crop slider, flip toggle, rotation (±90°)
   - Colour: base mode picker, base RGB display + picker, WB picker button,
     temp/tint sliders, saturation slider, and highlight/midtone/shadow color
     wheels
   - Tone: white/black point percentiles, gamma, shadows, highlights, one
     overall curve, and independent red/green/blue curves
   - Export: file type picker (TIFF/JPEG/PNG/DNG), frame slider, aspect ratio
     picker, folder selector, export buttons (individual/batch)
3. **Preview area:**
   - Process view selector (RAW / Threshold / Contours / Histogram / Full Preview)
   - Intermediate stage preview (upper, smaller)
   - Final preview (lower, larger)
   - Histogram overlay when Histogram mode selected
   - Click-to-pick WB base point and base colour on preview
4. **Advanced settings sheet:** Demosaic algorithm, gamma curve, noise reduction params, dust params, JPEG quality, TIFF compression, processor count override
5. **Export sheet:** Determinate progress bar (current/total), abort button, per-file error log with expandable details
6. **Settings management:** Copy/paste settings between photos, reset to defaults, save/load named presets, drag-to-reorder photo batch

### 3.4 Must-Have UX Improvements (done during port, not after)

- **Live preview with zoom/pan:** `NSScrollView` with pinch-to-zoom gesture and click-to-drag pan. Python/Tkinter had no zoom/pan at all.
- **Before/after split:** Press-and-hold or toggle switch to show RAW vs. processed side-by-side.
- **Keyboard shortcut reference:** `Cmd+/` overlay showing all available shortcuts, searchable.
- **Dark mode:** Free with SwiftUI (adapts to system appearance automatically).
- **Undo/redo:** `UndoManager` integration on `DocumentModel` for all parameter changes.
- **Batch reorder:** Drag to reorder photos in the sidebar list with haptic feedback.
- **Professional grading without default clutter:** Keep curves and three-way
  color wheels in collapsible advanced sections while preserving immediate
  preview feedback and numeric reset controls.

---

## Phase 4: Performance Verification & Polish

### 4.1 Performance Gates

| Metric | Target | Measurement |
|---|---|---|
| Cold pipeline (6K RAW → export) | ≥ 3× faster than Python | Wall clock, same hardware |
| Warm pipeline (cached crop + stats) | ≥ 5× faster than Python | Wall clock, same hardware |
| Full batch export (10× 6K RAW) | ≥ 4× faster than Python | Wall clock, same hardware |
| Memory per photo during export | ≤ Python baseline | `footprint` / Xcode Memory Graph |
| Curve/color-wheel preview vs. authoritative render | Within documented tolerance | Parameter-grid pixel comparison |
| Processed-RGB DNG interoperability | Opens with correct pixels, orientation, profile, and metadata | Multi-reader round-trip suite |
| RAW decode + half-size proxy | ≥ 2× faster than RawPy | `os_signpost` intervals |
| Perspective warp (4K × 4K) | < 5ms (GPU) | Metal System Trace |
| Dust inpainting (4K, 3 channels) | < 20ms (GPU) | Metal System Trace |
| UI refresh on slider drag | < 16ms (60 fps) | Instruments Time Profiler |

Log all results alongside the Python baseline in `docs/performance/`.

### 4.2 CI Pipeline

```
Git push
└── GitHub Actions (macOS runner)
    ├── Phase 0: Pixel-equivalence test suite
    │   ├── Run Swift pipeline over synthetic + real corpus
    │   ├── Compare output hashes to locked reference
    │   └── Fail if any pixel differs beyond documented tolerance
    ├── Phase 1: Unit tests (XCTest)
    │   └── ≥ 90% line coverage on FilmScanEngine
    ├── Phase 2: Performance benchmarks (opt-in via env var)
    │   ├── Compare to stored baseline
    │   └── Warn if regression > 10%
    └── Phase 3: UI snapshot tests
        └── Compare SwiftUI screenshots to reference (pointfreeco/swift-snapshot-testing)
```

### 4.3 Regression Prevention

- Every pixel test in Phase 0 is a CI-blocking gate. No merge that changes output pixels without regenerating the reference corpus.
- If a new algorithm produces visually better output, regenerate reference snapshots and commit them together with the algorithm change, with a rationale in the commit message.
- Performance regressions > 10% are CI warnings (not blockers). The PR author must document the tradeoff.

---

## Dependencies Summary

| Need | Option A (recommended) | Option B | Option C |
|---|---|---|---|
| RAW decoding | LibRaw via XCFramework + bridging header | `RAWKit` (commercial) | `CGImageSource` (limited RAW support, no gamma control) |
| Image processing | Accelerate (`vImage`, `vDSP`, `vvpowf`) | Metal Performance Shaders | OpenCV (C++ interop via bridging header) |
| Contour detection | Manual Suzuki-Abe implementation | OpenCV C++ interop | `Vision` (`VNDetectContoursRequest` — different output format, breaks pixel-equivalence) |
| Inpainting (Telea FMM) | OpenCV C++ interop (safe start) | Custom Metal compute kernel | Replace with median blur (simpler but loses equivalence) |
| Homography solve | `simd` / LAPACK (DGESVD via Accelerate) | Custom DLT | OpenCV |
| GUI | SwiftUI | AppKit | — |
| Snapshot testing | `pointfreeco/swift-snapshot-testing` | XCTest with manual PNG diff | — |

**OpenCV interop note:** OpenCV does not distribute as a Swift package. Interop requires a C++ bridging header, a module map, and linking against `libopencv_imgproc` and `libopencv_core`. Homebrew's `opencv` formula provides these. This is well-understood territory but adds build complexity. Limit OpenCV usage to the two hardest-to-port functions: `findContours` + `minAreaRect`, and `inpaint`.

---

## Remaining Delivery Order

1. **Finish Phase 0 coverage** — Expand the snapshot corpus from the committed
   helper fixtures to synthetic images, representative RAW files, intermediate
   stages, and parameter-grid variants.
2. **Phase 1.1, complete** — Standard image decoding and the thread-safe LibRaw
   wrapper produce decoupled 16-bit BGR arrays. The representative RAF corpus
   matches the Python/RawPy reference exactly at half size, with one
   full-resolution exact-equivalence gate.
3. **Phase 1.2, complete** — Threshold generation has exact pixel equality for 5
   dark/light combinations, matching Python `get_threshold` output.
4. **Phase 1.5 and 1.7, complete** — White balance coefficient adjustment and
   saturation adjustment are verified against Python float64 reference fixtures.
5. **Phase 1.4, complete** — Histogram equalisation has exact float64 equality
   for the current three-fixture corpus.
6. **Phase 1.12 and Phase 2 preview foundation, complete through Stage 3** —
   Curves, color wheels, live bindings, bounded scheduling, equivalence, and
   latency gates are implemented. Direct Metal-backed display and idle
   authoritative rendering remain deferred.
7. **Phase 1.13, complete** — TIFF/JPEG/PNG export plus the defined processed-RGB
   DNG contract, verified by round-trip and batch tests. Individual export,
   ExportManager batch primitives, and app-level lazy Export All are
   implemented.
8. **Phase 1.14, in progress** — Capture normalization/density primitives (Slice A),
    linear-input diagnostics (Slice B), manual rebate base measurement with
    roll-profile storage and precedence resolution (Slice C), initial
    automatic rebate candidates with confidence (Slice D), and generic C-41
    density-to-scene-linear renderer (Slice E) are complete as
    standalone engine APIs. Startup film-kind classification initializes new
    files as color negative, B&W negative, or slide with matching
    RawTherapee-compatible presets. The RawTherapee-compatible power-law
    inversion front-end is connected to preview and export, and app RAW
    imports/exports now use a RawTherapee camera-scan decode profile with
    linear output, disabled auto-bright/exposure boost, and LibRaw highlight
    reconstruction while the frozen RawPy decode profile remains available for
    exact fixture/benchmark parity. Continue with shared display rendering
    (Slice F), native RawTherapee-style highlight/noise protection, or UI region
    picking; capture/stock profiles and per-stock curves follow.
9. **Phase 1.3 and 1.2 cont.** — Contour detection + minAreaRect (OpenCV
   C++ interop), perspective warp (DLT homography + bilinear warp).
10. **Phase 1.8–1.9** — Dust detection and Telea FMM inpainting.
11. **Phase 1.10–1.11** — Complete remaining workflow orchestration around
    crop, perspective, dust, persistence, and settings migration.
12. **Phase 3** — Finish crop, perspective, dust, persistence, packaging, and
    release workflows. Export UI and batch export are already implemented.
13. **Phase 2** — Replace remaining measured hot paths with Metal or Accelerate
    implementations. Profile before and after each change.
14. **Phase 4** — Performance gates, packaging, CI hardening, release
    validation, and Python retirement.

Each phase should produce a verifiable increment. The Swift application is the
primary product now, but Python cannot move to `archive/python/` until the
required crop/perspective/dust stages, fixture independence, and release
validation are complete. The authoritative current status is
[`docs/development/native-macos.md`](../development/native-macos.md).
