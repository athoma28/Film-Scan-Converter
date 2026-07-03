# Native macOS Development

This page is the authoritative status for the Swift/macOS rewrite. It describes
what works now, the current development step, and the order of upcoming work.
The detailed [macOS native roadmap](../improvements/MacOS-Native-Roadmap.md) is
the design reference, not a statement that every listed item is implemented.

**Last updated:** 2026-07-02 (293 tests across 19 files; release bundle assembly, dependency embedding, hardened-runtime signing support, contract validation, ZIP creation, and extracted-archive validation are complete; Developer ID notarization and clean-machine installation remain; usability work now includes persistent edit markers, immediate pasted-look median refresh, apply-to-all-open-files, mirrored rotation semantics, instant inspector switching, adjustable 2–32 file preloading, append-selected export queuing, and neutral-white zero-light inversion on CPU/GPU; RAW preview remains half-size while memory-bounded export re-decodes full-resolution)

## Goal

Build a native Swift and SwiftUI version of Film Scan Converter that:

- preserves tested compatibility for processing behavior shared with the
  legacy Python implementation;
- improves preview and batch-processing performance;
- is the primary product and the only target for new features;
- provides a low-latency corrected camera preview when the DSLR or capture
  adapter exposes a video feed to macOS.

## Transition State

The Swift application is the primary product and all new features, processing
behavior, and UI work belong here. The Python/Tkinter application is
maintenance-only legacy code: it remains available for compatibility
regressions, frozen fixture generation, and workflows the native app has not
yet replaced.

The Python source must not move to `archive/python/` until the retirement gates
in [Legacy Python Status And Retirement](../legacy-python.md) are complete.
Those gates include dust handling, fixture independence, and release
validation. Native crop detection and
perspective correction are connected to preview and export.
Native export is complete.

## Current Development Step

The color-accuracy and photographic-adjustment track is complete. All six
perceptual-slider modernization slices are verified against
the CPU authoritative path across 2,725 GPU comparisons (0 failures, max
2/255). Legacy RGB-gain and HSV functions remain for compatibility fixtures.
The preceding film-specific camera-scan track remains operational: Slices A
through G are wired into the app, and the density pipeline is connected to both
preview and export. The power-law (RawTherapee-compatible) inversion remains
the default front-end; the density pipeline remains an explicit inspector
option with a CPU render fallback.

Dust development is paused after Slice 1: deterministic native dust-mask
detection matches the frozen Python/OpenCV reference, while Telea inpainting
and app wiring remain deferred.

**Active step: finish packaging and release validation. A reproducible release
script now builds a self-contained app, embeds and rewrites non-system dynamic
libraries, supports Developer ID hardened-runtime signing, validates the bundle
and signature, emits a versioned ZIP, and revalidates the extracted archive.
Developer ID notarization, Gatekeeper, and clean-machine install/launch checks
remain. Post-dust workflow/settings work
is complete: per-file corrections are keyed by standardized source path,
loaded at launch, and atomically saved after edits; user-named presets use a
separate versioned atomic store; and correction settings can be copied through
the system clipboard. Applying a preset or pasted look preserves the target
frame's orientation, crop geometry, and measured film-base state. Corrupt
per-file settings or preset data do not prevent startup.**

## Progress

| Area | Status | Current result |
|---|---|---|
| Phase 0: regression gate | In progress | Swift tests consume frozen Python-generated `.npy` fixtures and compact RAW hash manifests. Standard decode fixtures cover 8-bit PNG, grayscale PNG, BMP, JPEG, and 16-bit TIFF. Five half-size RAF decodes and one full-resolution RAF decode require exact SHA-256 equality with RawPy when the local `sample-raw` corpus is present; when it is absent, those corpus-specific tests are explicitly reported as disabled rather than silently passing. The full intermediate-stage and parameter-grid corpus is not complete. |
| Phase 1: processing engine | In progress | The frozen RawPy profile remains exact for fixtures. The camera-scan profile disables auto-bright/exposure boost, enables LibRaw highlight reconstruction, records ISO and executed stages, and selects bounded low-ISO sharpening or medium/high-ISO denoising. Full-resolution Bayer decode uses the RCD callback; full-resolution X-Trans decode uses LibRaw's three-pass Markesteijn interpolation. Half-size preview decode bypasses demosaicing. Film-negative inversion and density processing feed one unclamped linear adjustment seam. Safe global tone controls (Exposure EV, Brightness, Contrast, Highlights, Shadows) and protected color controls use luminance-preserving opponent axes; frozen RGB-gain/HSV operators remain available. Robust statistics use at most 65,536 deterministic samples. Native dust-mask detection uses fixed-size percentile histograms, O(pixels) square morphology, and bounded connected-component scratch storage; three frozen Python/OpenCV fixtures match exactly. Density processing, contour detection, and perspective crop are connected to preview/export. Telea inpainting, direct camera-to-Rec.2020 conversion, and exact RawTherapee denoise/sharpen kernels remain limitations. |
| Phase 2: accelerated rendering | In progress | Live camera preview uses a Metal-backed Core Image context. Still-file correction uploads one bounded 16-bit proxy per selection, applies the current correction controls in one custom GPU kernel, and keeps only one in-flight render plus the newest pending snapshot. The kernel includes the power-law film-negative inversion, protected color/tone adjustments, curve LUT sampling, and three-way color wheels. The production renderer matches the authoritative CPU path across 2,655 comparisons with a maximum difference of 2/255. On the M4 Pro, the reproducible adjustment-heavy release benchmark at 1080×720 improved from a 3.9959 ms p95 baseline to 2.9641–3.0286 ms across four post-change runs (at least 24.2%) without changing dimensions; the app uses a 640-pixel interactive proxy. The density pipeline is connected to preview and export through the authoritative CPU path; a product-integrated GPU density preview and idle authoritative rendering remain deferred. |
| Phase 3: SwiftUI application | Interactive correction + export workflow | Per-file corrections persist and the browser marks actual user edits rather than cache residency. Copy/paste refreshes image-derived negative medians immediately; the current look can be applied to every open file while preserving each frame's geometry. Edit/Grade/Export pages remain mounted for immediate switching. Export supports TIFF, JPEG, PNG, and DNG with memory-bounded sequential execution, and the selected file can be appended while an export is active. A user-selectable 2/4/8/16/32-session cache predecodes the corresponding forward lookahead; larger values intentionally trade RAM for faster switching. Zero-light pixels in negative inversion are forced to neutral white on both CPU and GPU. End-to-end latency still requires real-file verification. |
| Phase 4: performance and polish | Release validation in progress | CI builds and tests the current native package. The representative RAW decode and quality benchmark is complete. Self-contained app/ZIP assembly, Homebrew dependency embedding, bundle-relative load paths, hardened-runtime signing support, bundle validation, strict local signature verification, and extracted-archive revalidation are complete. Developer ID notarization, Gatekeeper, clean-machine install/launch checks, and UI snapshots remain. |

## Planned Native Capabilities

Curves and color wheels are complete:
- an overall tone curve plus independent red, green, and blue channel curves
  (piecewise-linear interpolation, 65536-entry 16-bit CPU LUTs, 256×256 8-bit
  GPU LUT texture);
- highlight, midtone, and shadow color wheels backed by smoothstep tonal masks
  with luminance preservation.

Export is complete for all four target formats:
- TIFF (16-bit deep, optional LZW compression);
- JPEG (8-bit, configurable quality 0–100%);
- PNG (16-bit deep, lossless);
- DNG (processed 16-bit RGB, valid TIFF container with DNG IFD tags, not
  claiming untouched camera RAW);
- individual and batch-all export with actor-based export primitives,
  memory-bounded sequential app-level Export All, parallel `ExportManager`
  batch support for prebuilt request sets, collision-safe `-2`, `-3`, ...
  destination suffixes, cancellation propagation,
  error-per-file reporting, and partial-file cleanup.

Film-specific camera-scan processing now has a separate staged track based on
the [film-processing research brief](../film-processing-research.md). The
RawTherapee-compatible power-law inversion is complete and operational as
a preview-compatible front-end. Integrated slices provide capture
normalization, manual and automatic rebate measurement, generic C-41
conversion, shared display rendering, and separated capture/stock/roll
profiles. Preview and export share the density path, including aligned flat-field
calibration. Per-stock inverse-density curves, fitted matrices, and optional
residual LUTs remain future work.
The shared color/adjustment foundation is complete: versioned semantic
parameters, the unclamped linear seam with robust statistics, protected color
controls, safe global tone controls, continuous UI bindings, and numerical plus
visual regression gates. Stock-specific calibration follows after the active
dust-removal replacement gate.
The detailed order and acceptance criteria are maintained in the
[native roadmap](../improvements/MacOS-Native-Roadmap.md#film-specific-camera-scan-processing-track).

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
- A narrow C module boundary around thread-safe LibRaw (`CLibRawShim.c`), providing
  two decode paths: `fsc_decode_raw_direct` (mmap I/O, no C-side BGR→RGB malloc
  — Swift does single-pass swizzle during `[UInt16]` creation) and the legacy
  `fsc_decode_raw` (kept for caller compatibility). Both return owned 16-bit
  buffers with no LibRaw lifetime exposed to Swift.
- Exact RawPy-equivalent half-size decoding for all five representative X-T5
  RAF files and exact full-resolution decoding for one representative RAF.
- A reproducible [native RAW decode and quality benchmark](native-raw-benchmark.md)
  proving exact decoded pixels for all five RAFs at half and full resolution.
- A separate RawTherapee camera-scan RAW decode profile used by app RAW import,
  background swap, predecode, and export. It keeps 16-bit sRGB output, disables
  LibRaw auto-brightening and exposure boost, and enables LibRaw highlight
  reconstruction. The frozen RawPy profile remains available for exact fixtures.
- The camera-scan decoder exposes captured ISO plus executed-stage flags.
  ISO below 800 receives bounded sharpening; ISO 800 through 3199 receives mild
  denoising; ISO 3200 and above receives stronger denoising. These thresholds
  and filters are native policy approximations, not RawTherapee defaults or
  exact algorithm ports.
- A GPL-compatible RCD callback is installed at LibRaw's Bayer interpolation
  boundary. It runs only for explicitly requested full-resolution Bayer decode.
  Half-size decode bypasses interpolation. Full-resolution X-Trans camera-scan
  decode explicitly uses LibRaw's three-pass Markesteijn interpolation. No Bayer RAW exists in the current local corpus, so RCD has compile and
  routing coverage but not a committed real-file pixel fixture.
- C bridge debug logging (`FSC_LOG` macro) is compile-time gated on `#ifdef DEBUG`,
  eliminating `fprintf` + `fflush` overhead from release builds. Debug builds retain
  full per-step LibRaw instrumentation.
- Background RAW decoding and preview through the same engine-buffer path used
  by standard images.
- Embedded JPEG thumbnail fast-path: `RawImageDecoder.extractThumbnail()` extracts
  the camera-processed JPEG preview from RAW files via `libraw_unpack_thumb` at
  65–110 ms (10–15× faster than half-res LibRaw decode). `AppModel.loadSelection()`
  shows the JPEG instantly as the interactive preview while a background
  `rawSwapTask` decodes the full RAW buffer and seamlessly swaps it in at the same
  correction settings and proxy dimensions.
- `StillPreviewRenderer` caches the compiled `CIKernel` and `CIContext` as shared
  static properties, eliminating per-selection kernel recompilation and Metal
  context creation. The kernel is compiled once on first use; subsequent previews
  reuse the cached objects.
- `UInt16Image.makePreviewCGImage()` and `makePreviewCGImage16()` use pre-allocated
  directly-indexed arrays instead of per-component `append()`, reducing allocation
  traffic on every preview generation.
- A bounded 640-pixel correction preview proxy that rerenders verified engine
  corrections in the background without changing the full decoded source. This
  CPU path is currently suitable only as an idle correctness preview, not
  continuous real-time interaction.
- A user-selectable 2/4/8/16/32-session decoded/proxy/renderer cache. Selection
  starts cancellable sequential utility-priority predecode for the configured
  forward lookahead. The default remains two; higher settings explicitly trade
  substantially more RAM for faster switching through large batches.
- Embedded RAW thumbnail and full-decode swap behavior is covered by both
  decoder-level and app-model tests when the local `sample-raw/` corpus is
  available. Corpus-specific tests are conditionally disabled with an explicit
  reason on machines that do not have the untracked RAF files.
- A reusable Core Image/Metal still-preview renderer that uploads one bounded
  16-bit proxy per selection, disables implicit working-space conversion, and
  fuses film negative power-law inversion, grayscale, white balance, tone, HSV
  saturation, curves, and color wheels into one GPU color kernel. The latest
  dedicated adjustment benchmark. Its 120-render, adjustment-heavy 1080×720
  release workload measured 2.9641–3.0286 ms p95 across four post-change runs
  on the M4 Pro, versus a 3.9959 ms p95 baseline before constant-time gamut
  limiting. The latest run measured 2.7034 ms median and 3.0015 ms p95.
  Dimensions and the 16-bit upload source are unchanged.
- Bounded latest-value-wins still-preview scheduling with at most one render in
  flight and one newest pending parameter snapshot.
- Display-rate coalescing with an 8 ms inter-frame delay, allowing up to 120 Hz
  presentation while preventing render backlog during rapid slider interaction.
  The real `AppModel` rapid-update integration test verifies coalescing and the
  latest displayed parameter state. The release adjustment benchmark includes
  protected color/tone controls, curves, and color wheels (1080×720,
  3.0015 ms p95 in the latest recorded run).
- Per-file, session-scoped SwiftUI correction controls for film mode,
  orientation, temperature, tint, gamma, shadows, highlights, and saturation,
  plus reset and original/corrected comparison.
- A versioned `PhotoAdjustmentParameters` contract with semantic floating-point
  exposure, tone, temperature-in-mired, tint, saturation, and vibrance intent.
  Its tested center-weighted mapping preserves exact neutral values and old
  JSON settings migrate deterministically while the legacy pixel operators
  remain unchanged.
- A shared `RenderReadyLinearImage` BGR contract for the power-law and density
  front-ends. It preserves negative and over-range floating-point samples until
  the display/output transform. Reusable statistics report linear and
  log-luminance p01/p50/p99, per-channel low/high clipping ratios, and normalized
  tone anchors from deterministic sampling hard-capped at 65,536 pixels.
- Protected color processing on the shared linear seam: Temperature and Tint
  use zero-luminance Rec.2020 opponent axes; Saturation changes chroma while
  preserving luminance; Vibrance selectively favors muted colors. Highlight
  and gamut-risk attenuation plus binary hue-preserving chroma reduction keep
  output finite and bounded without rotating opponent hue. The same operator
  is implemented in the production Core Image kernel and tested within 2/255
  of the authoritative CPU path.
- Safe global tone controls on the shared unclamped linear seam: Exposure (EV,
  pure multiplicative gain), Brightness (additive linear offset at 18% gray
  reference), Contrast (pivot-based power curve around 18% gray with exp2
  mapping), Highlights (soft compression/expansion weighted on values above 0.5
  linear), and Shadows (gain-weighted lift/darken for values below 0.5 linear).
  All five controls operate before display rendering, preserve luminance
  uniformity (same per-pixel factor applied to all channels), and have CPU/GPU
  parity within the existing 2/255 tolerance. The legacy integer
  gamma/shadows/highlights path is retained for frozen compatibility fixtures.
  19 focused tests cover neutral identity, positive/negative extremes,
  combined application, channel ratio preservation, gain flooring, dimension
  preservation, and finite-output guarantees.
- A three-page Edit/Grade/Export inspector that keeps primary film, light, and
  color adjustments separate from curves/color grading and output settings.
  A reusable `AdjustmentSlider` component bound to continuous `Double` state
  with focusable native keyboard interaction, formatted value display with
  semantic unit suffixes (EV, %), reset button, double-click reset, and
  accessibility labels. All 16 inspector sliders use this shared
  component. Advanced film-negative profile coefficients are collapsed by
  default and use preset-centered ranges.
- Draggable shadow, midtone, and highlight color wheels with hue mapped around
  the wheel, strength mapped from center to edge, position markers, and
  double-click reset.
- Film-mode-aware inspector states: Original mode explicitly disables all
  corrections, while B&W mode keeps tone controls available and disables color,
  curves, and color wheels instead of presenting controls that processing
  ignores.
- A piecewise-linear curves graph that displays the same interpolation used by
  the authoritative engine and GPU LUT.
- Perspective warp via DLT homography solver (8×8 LU decomposition via LAPACK `dgesv_`)
  and bilinear interpolation with border-constant zero for out-of-bounds source
  coordinates. Matches OpenCV `getPerspectiveTransform` homography output exactly
  and produces standard bilinear interpolation with documented tolerance against
  OpenCV `warpPerspective` for out-of-bounds regions. 14 tests covering identity,
  translation, perspective, self-consistency, round-trip, and multi-channel support.
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
- Exposure adjustment matching Python's float32 rounding boundaries exactly.
  Covers neutral normalization and clipping, gamma, shadows, highlights, and
  combined adjustments.
- Standalone film-negative capture normalization and density-domain primitives:
  per-channel BGR black levels, matched flat-field normalization, safe
  transmittance clamping, optical-density conversion, and manual base-density
  subtraction. Tests verify known ratios, clipping behavior, matched-exposure
  invariance, rebate-zero behavior, and the combined first-slice pipeline.
- RawTherapee-compatible film negative power-law inversion with reference
  resolution from 20%-border-cut channel medians to a `1/24` linear output
  reference. Per-channel exponent model:
  `output = multiplier × pixel^-(greenExp × ratio)`. Adopted presets matching
  RawTherapee's `Film Negative.pp3` (RedRatio=1.36, GreenExp=1.5, BlueRatio=0.86
  for color negative) and `Film Negative - Black and White.pp3` (all ratios=1.0).
  Processing parity across the CPU (Double) and production Metal CIKernel paths.
  SwiftUI controls with preset picker (Off / Color Negative /
  Black & White) and per-channel ratio/exponent sliders showing computed exponents
  and measured medians. Focused processing and production-renderer tests verify
  inversion direction, multiplier calibration, deep-shadow regression prevention,
  and CPU/Metal equivalence.
- Automatic startup classification for new imports: low-chroma scans initialize
  as B&W negative with the RawTherapee B&W preset, orange-mask channel medians
  initialize as color negative with the RawTherapee color-negative preset, and
  remaining positive-looking scans initialize as slide. Existing per-file
  settings are preserved and never overwritten by classification.
- Generic C-41 density-to-scene-linear renderer (Slice E, engine-only):
  `genericC41SceneEstimate()` applies per-channel BGR density slopes/offsets to
  produce scene-linear positive values. `normalizeSceneExposure()` scales by
  reciprocal of median green channel. `densityToSceneLinear()` composes capture
  normalization, optical density, base subtraction, scene estimate, and exposure
  normalization into one call. Codable `GenericC41Profile` with identity default
  (slopes=1.0, offsets=0.0) and nonnegative-slope precondition. 9 focused tests
  cover identity, channel-specific slopes/offsets, monotonicity, channel
  isolation, extreme density bounds, zero-median fallback, JSON round-trip, and
  composed pipeline correctness.
- Optional AVFoundation live camera preview.
- GPU-backed live preview inversion, exposure, and saturation controls.
- Late-frame dropping and a 20 FPS processing throttle.
- Camera permission metadata embedded in the executable.
- macOS CI that runs Swift tests and builds the app.
- Legacy Python CI that protects compatibility behavior and fixture tooling.
- Native export to TIFF, JPEG, PNG, and DNG with per-format options (JPEG
  quality, TIFF LZW compression), frame-percent border, and aspect-ratio presets.
- Individual and batch-all export from the decoded working image with applied
  corrections, background processing, per-file destination,
  error-per-file reporting, and partial-file cleanup. The app-level Export All
  path lazily decodes, classifies, processes, and writes unloaded files one at a
  time so memory does not grow with the import list. Standard-image exports
  retain source resolution; RAW export re-decodes one file at a time at full
  resolution while interactive previews retain the bounded half-size decode.

## Important Limitations

- Standard images with alpha channels are rejected because the current
  processing pipeline supports grayscale and three-channel BGR buffers.
- Exact standard-decode equivalence is currently locked for the committed PNG,
  BMP, and TIFF fixtures. JPEG is locked to the documented tolerance above.
  Broader real-file coverage, including embedded color profiles and orientation
  metadata, remains to be added to the frozen corpus.
- The native engine has parity-tested dust-mask detection but still lacks Telea
  FMM inpainting. The app therefore does not yet expose dust removal. This is
  the main remaining replacement gate.
- Interactive previews do not yet integrate dust removal. Film-base detection,
  manual rebate selection, crop detection, and
  perspective correction are integrated. Per-file correction settings persist
  across launches, and named presets plus system-clipboard copy/paste are
  available in the Edit inspector.
- The native RawTherapee parity path is still partial. RawTherapee's source
  order is `preprocess` (black/white scaling, bad pixels, flat field/gain maps,
  green equilibration), `demosaic`, `getImage` (white balance, optional highlight
  recovery, baseline exposure, color conversion), then `filmNegativeProcess`
  unless the tool is in input color space. RawTherapee's `FilmNegativeParams`
  default to working color space with zero input/output references, so the
  exponent ratios alone are not the whole preset behavior. The app now includes
  RawTherapee's default output reference and the two Film Negative preset curves.
  Linear Rec.2020 inversion placement, an RCD callback for explicitly requested
  full-resolution Bayer decode, and ISO-tier noise/detail processing are
  implemented. Full-resolution X-Trans export uses three-pass Markesteijn
  demosaicing. Direct camera-to-Rec.2020 conversion, app-path Bayer RCD, and exact
  RawTherapee noise kernels remain pending.
- The density-domain film-negative API is now connected to preview and export
   via the `densityPipelineEnabled` toggle. When enabled, `densityToSceneLinear`
   + `renderDisplay` replaces the power-law inversion in both the preview and
   export paths. The power-law (RawTherapee-compatible) inversion remains the
   default. The density pipeline currently uses a CPU render path with GPU
   fallback; a dedicated GPU-accelerated density pipeline kernel is future work.
   Flat-field loading is supported but the flat-field must be manually selected;
   automatic flat-field association per capture profile remains roadmap work.
   Per-stock inverse density curves (Slice H) for Portra 400, Portra 160,
   Ektar 100, and Gold 200 follow the shared color/adjustment contract and its
   regression gate rather than preceding them.
- Still-image slider bindings and the initial GPU correction renderer are
  implemented with bounded latest-value-wins scheduling and display-rate
  coalescing (8 ms inter-frame delay). The actual Core Image renderer is
  verified against the authoritative CPU path across 2,655 comparisons with a
  maximum difference of 2/255. Its adjustment-heavy release benchmark improved
  from a 3.9959 ms p95 baseline to 2.9641–3.0286 ms across four post-change
  runs (at least 24.2%) at unchanged 1080×720 dimensions.
  A direct Metal-backed preview surface and idle authoritative
  rendering remain. See the
  [real-time still preview plan](realtime-preview-plan.md).
- Several intermediate Python pipeline stages use float32 arithmetic
  (`cv2.boxPoints`, `matplotlib.colors.rgb_to_hsv`). Swift implementations
  using Double (float64) must cast to Float for precision-sensitive comparisons
  or accept documented ≤1 LSB tolerance after conversion back to 16-bit.
- The representative RAF files remain outside version control. Their compact
  RawPy hashes are committed, so local runs with `sample-raw/` prove exact
  equivalence; CI compiles and exercises non-corpus decoder contracts.
- Half-resolution and full-resolution native RAW decode performance is effectively
  equal to RawPy on current hardware (M4 Pro, 14 cores). The C bridge uses mmap I/O
  instead of buffered `fopen` and the `fsc_decode_raw_direct` path eliminates the
  C-side malloc + BGR→RGB swizzle copy; the BGR→RGB conversion now runs in a single
  pass during `[UInt16]` creation in Swift. Full-resolution decode was previously
  19.7% slower due to a double-copy bridge design that has since been removed.
  See the benchmark report for current numbers.
- Live camera preview works only when macOS exposes the DSLR or capture adapter
  as an AVFoundation video device. Many DSLRs require a vendor SDK or tethering
  adapter for live view.
- Live camera preview is an 8-bit alignment and correction aid. Final output
  must continue to use the full 16-bit RAW capture and pixel-equivalent pipeline.
- The Python application is maintenance-only legacy code, but remains the only
  complete historical workflow with dust removal until the retirement gates are
  complete. Native crop/perspective processing is operational.

The native test suite currently contains **296 tests** across 19 test files,
all passing in the latest local run. The 500-render latency benchmark is skipped
by default and runs when `RUN_PERFORMANCE_TESTS=1` is set.

## Verified Native Features

- TIFF/JPEG/PNG/DNG export contract with individual and lazy batch-all
  workflows. TIFF exports 16-bit deep with optional LZW compression; JPEG
  exports 8-bit with configurable quality; PNG exports 16-bit lossless; DNG
  produces a valid TIFF container with DNG-specific IFD tags for processed
  16-bit RGB output, explicitly labelled as processed rather than camera RAW.
- ExportManager actor with sequential and parallel (`exportBatch`) modes,
  cancellation propagation, per-file error reporting, and partial-file cleanup
  on failure. The app-level Export All path intentionally uses the sequential
  lazy-decode mode so it never retains the whole processed batch in memory;
  `exportBatch` remains available and tested for callers that already hold a
  bounded request set. Memory-bounded concurrency heuristic based on system physical
  memory and active processor count.
- Export inspector section in the SwiftUI UI: format picker, JPEG quality
  slider, TIFF compression picker, frame-percent slider, aspect-ratio preset
  picker, destination folder selector with system open panel, Export Selected
  and Export All buttons, determinate progress bar, and expandable per-file
  error display. Export All decodes unloaded files on demand and does not retain
  an unbounded decoded-image dictionary.
- 19 export tests covering all four format round-trips, 1-channel and 3-channel
  images, JPEG quality file-size ordering, TIFF LZW compression, DNG byte-order
  and minimum-size checks, framed output dimensions, batch parallelism (8 images
  at concurrency 4), sequential progress completion, cancellation behaviour,
  intermediate-directory creation, JSON round-trips for all enum cases, and
  display-name/extension properties.
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
- Direct production Core Image renderer comparison covers 2,655 cases with zero
  failures and a maximum difference of 2/255. An automated 20-configuration
  parameter grid test verifies the production renderer against the authoritative
  CPU path across film types, WB, exposure, saturation, curves, color wheels,
  and per-channel curves on every test run.
   B&W negative correctly skips curves and color wheels in both CPU and production
   GPU paths. Focused tests cover LUT construction (identity, unsorted input, duplicate
   inputs, extrapolation, boundaries), mask ranges and overlap, hue wrapping,
   zero-strength identity, three simultaneous wheels, and direct production
   GPU-CPU equivalence.
- Density pipeline connected to preview and export. The `correctedPreview()`
  entry point branches to the density pipeline path (`densityToSceneLinear` +
  `renderDisplay`) when `densityPipelineEnabled` is true and a base density is
  available. The existing power-law path is preserved as the default.
- `ProcessingParameters` extended with `densityPipelineEnabled`,
  `densityBaseDensity`, `densityC41Profile`, and `densityDisplayParams`.
- Rebate detection auto-wires base density: selecting a rebate candidate or
  saving a roll profile automatically enables the density pipeline and populates
  the base density, C-41 profile, and display rendering parameters from the
  resolved `ResolvedPipelineProfile`.
- `resolveAndApplyDensityPipeline()` composes CaptureProfile, FilmStockProfile,
  RollProfile, and frame measurements through the ProfileStore resolution
  pipeline and applies the result to the current processing parameters.
- Flat-field calibration image loading via open panel with channel/aspect-ratio
  validation. The flat field is resized to exact source geometry, receives the
  same crop/orientation transform as the scan, and is used for rebate
  measurement plus preview/export rendering. Loading or clearing it immediately
  submits a new preview.
- Density pipeline toggle and status display in the Film Base inspector section.
- Manual rebate rectangle selection by dragging over the displayed preview.
- Contour detection and crop box computation ported in pure Swift
  (`ContourDetection.swift`, 18 tests). Connected-component analysis via
  Union-Find, convex hull via Andrew's monotone chain, and minimum-area
  bounding rectangle via rotating calipers. `findOptimalCrop()` returns a
  normalized `RotatedRect` matching the Python `find_optimal_crop` contract.
  `RotatedRect.boxPoints` produces 4 float-precision corner points.
  Wired into AppModel with `detectCrop()`, configurable `darkThreshold`/
  `lightThreshold` sliders, and a Film Frame inspector section with crop
  status display (`detectCrop` triggers threshold generation then contour
  detection on a bounded worker task). Large-image contour coordinates are
  restored to full-resolution space before return.
- Per-file crop geometry is Codable in `ProcessingParameters` and is applied by
  the shared processing entry point through the native homography/bilinear warp,
  so preview and export use the same perspective-corrected result.

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
6. Do not restore the removed standalone histogram-equalisation prototype
   without a product requirement, shared preview/export wiring, and workflow
   coverage.
7. ~~Implement authoritative overall/per-channel RGB curves and
   highlight/midtone/shadow color wheels, then add matching GPU preview
   controls and visual-equivalence tests.~~ Done. 19 tests covering curve LUT
   construction, mask ranges, per-channel isolation, luminance preservation,
   and GPU-vs-CPU equivalence for curves, wheels, and combined.
8. ~~Implement TIFF/JPEG/PNG export and the defined processed-RGB DNG contract,
   including metadata, round-trip, cancellation, and batch-export tests.~~ Done.
   19 export tests covering all four formats, round-trip decode, batch
   parallelism, cancellation, frame/aspect ratio, and JSON coding.
9. ~~Complete the color-accuracy and perceptual-slider modernization track.~~
   All six slices are done: semantic adjustment contract, shared unclamped
   linear/statistics seam, protected color controls, safe global tone controls,
   reusable continuous-Double AdjustmentSlider, and the perceptual regression
   gate with 2,725 GPU-vs-CPU comparison verifications (0 failures, max
   2/255). Per-stock Slice H calibration remains deferred.
10. ~~Wire manual/automatic rebate selection and the completed density/display
     APIs into preview/export, then separate capture, stock, and roll profiles.~~ Done.
     The density pipeline (`densityToSceneLinear` + `renderDisplay`) is connected to
     both preview and export via `ProcessingParameters.densityPipelineEnabled`. Rebate
     detection auto-wires base density into the density pipeline. `resolveAndApplyDensityPipeline`
     composes CaptureProfile, FilmStockProfile, and RollProfile into the processing
     parameters. Flat-field calibration validates geometry and is aligned through
     rebate measurement, preview, crop, orientation, and export. GPU density
     pipeline kernel remains future work.
11. ~~Port contour detection and crop box computation (requires OpenCV C++ interop
      for `findContours` + `minAreaRect`).~~ Done. Connected-component analysis
      (Union-Find), convex hull (Andrew's monotone chain), and minimum-area
      bounding rectangle (rotating calipers) implemented in pure Swift
      (`ContourDetection.swift`, 18 tests). Returns a normalized `RotatedRect`
      matching the Python `find_optimal_crop` contract. Wired into AppModel with
      `detectCrop()`, `darkThreshold`/`lightThreshold` sliders, and crop status
      display in the Film Frame inspector section. Perspective warp remains for item 12.
12. ~~Port perspective warp (DLT homography solve + bilinear warp).~~ Done.
    `PerspectiveTransform.computeHomography` and `PerspectiveTransform.warpPerspective`
    implemented in `PerspectiveWarp.swift` with Double precision bilinear interpolation
    and border-constant zero for out-of-bounds source coordinates. It is connected
    to per-file crop processing for preview/export. 18 focused tests cover all eight
    committed fixtures plus identity, translation, homography, and self-consistency.
13. Port dust handling. Dust-mask detection is complete with frozen
    Python/OpenCV parity fixtures and bounded-memory morphology. Telea FMM
    inpainting, shared preview/export integration, and the app control are paused.
14. ~~Complete post-dust settings management: atomic per-file persistence,
    named presets, and system-clipboard copy/paste that excludes target-specific
    crop/orientation and measured film-base state.~~ Done.
15. Complete packaging and release validation. Self-contained app/ZIP assembly,
    non-system dependency embedding, load-path rewriting, hardened-runtime
    signing support, automated bundle/signature checks, extracted-archive
    revalidation, and the
    [release runbook](native-release.md) are complete. Obtain a Developer ID
    signature, notarize and staple a candidate, then complete Gatekeeper and
    clean-machine launch/install checks.
16. Expand the frozen corpus to cover intermediate stages and parameter-grid
    variants.
17. ~~Connect completed engine stages to the SwiftUI preview panel.~~ Initial
    interactive correction workflow complete; finish real-file latency
    verification, then expand it as new engine stages land.

### Deferred Workflow Backlog

These user-reported workflow items are recorded for development after the
current release-validation work. They are not active implementation work yet.

1. **Sidebar multi-selection and Export Selected.** Replace the sidebar's
   single `URL?` selection contract with a `Set<URL>` plus a distinct primary
   file used by the preview and inspector. SwiftUI's `List(selection:)` can then
   provide native Shift-click range selection and Command-click toggling while
   parameter editing remains scoped to the primary file. `Export Selected`
   should snapshot the ordered selected URLs and feed them through the existing
   lazy sequential export path, preserving import order, bounded memory,
   cancellation, progress, and per-file errors. Add interaction-level coverage
   for range/toggle selection and an app-model test proving only selected files
   export.
2. ~~**Confidence-gated same-roll hint for film-kind classification.**~~ Done.
   An explicit non-crop film identity on the first imported file becomes a
   session-only weak prior. It is applied only when classifier confidence is
   below 0.65, does not copy corrections, and does not reclassify persisted or
   user-edited settings. Confident slides and low-chroma B&W scans override it;
   automatic results remain editable. Deterministic engine and app integration
   tests cover prior/no-prior, mixed-roll strong evidence, and predecoded later
   files.
3. **PNG export regression (`UInt16Image.ExportError 2`).** Partially complete.
   PNG now has a tested explicit 16-bit little-endian RGBA/no-alpha layout,
   writes through a unique same-directory staging file, commits atomically, and
   removes staging output on every failure path. Export errors now describe the
   format, destination, failing stage, and underlying filesystem error when one
   is available rather than displaying an opaque enum number. Existing engine
   round-trip and real app-path PNG tests remain green. Reproduction with the
   originally affected source/destination and macOS version is still required
   before calling the reported regression fully resolved; ImageIO does not
   expose a causal error object when `CGImageDestinationFinalize` only returns
   `false`.
4. **Contact-sheet export.** Add a Contact Sheet action operating on the current
   multi-selection (or all imports when explicitly chosen). Default to the
   primary/first selected file's correction settings, with an option to choose
   a named preset before rendering. Decode, process, resize to a maximum
   500-pixel thumbnail, and release each source sequentially; retain only the
   small thumbnails needed for final composition. Compute a balanced grid from
   item count and thumbnail aspect ratios, use consistent gutters/background,
   preserve aspect ratio without cropping, and export one image through the
   normal destination/error flow. Define output-dimension/pixel-budget limits
   and test ordering, mixed orientations, preset application, cancellation,
   and memory bounds.
5. **Appendable export queue.** First increment complete: while sequential export
   is active, the selected file can be appended, exact repeats are rejected,
   collision-safe destinations are reserved, and progress updates dynamically.
   Remaining work: replace the app task
   with a persistent in-process queue owned by one actor. Starting another
   individual, selected-files, all-files, or contact-sheet export while work is
   active should append a frozen job snapshot instead of rejecting it or
   replacing the active task. Show the active item and ordered pending jobs,
   allow pending jobs to be removed or reordered, and distinguish cancelling
   the active item from clearing the queue. Keep execution sequential by
   default so full-resolution RAW decode remains memory-bounded; deduplicate
   only exact accidental repeats, not intentional exports to different
   destinations or with different settings. Persisting unfinished jobs across
   app launches is out of scope until destination security-scoped bookmark
   behavior is designed and tested.
6. **Adaptive operation-duration estimates.** Record coarse completion timing
   for named stages such as RAW decode, processing, resize, and format write.
   Periodically fold those log events into a tiny versioned statistics file
   stored with application support data using atomic replacement. Estimate
   duration by operation plus a small set of meaningful predictors (megapixels,
   RAW/standard source, demosaic path, output format, and compression), using a
   bounded rolling sample or exponentially weighted average so old hardware or
   software behavior decays. Never store source paths or image content. Use the
   estimates to weight multi-stage and queued progress bars and show an ETA,
   while falling back to honest indeterminate or equal-stage progress when the
   sample count is too small. Clamp outliers and add deterministic tests for
   migration, corrupt-file recovery, sparse samples, and estimate stability.
7. **Profile and reduce full-resolution export latency.** Establish a release
   benchmark using representative approximately 40 MP RAW files and emit
   signposts around decode/demosaic, correction stages, geometry/frame work,
   color conversion, and encoding/finalization. Report cold and warm timings,
   peak resident memory, output hashes, and per-stage percentages before making
   changes. Optimize only the dominant measured stages: likely candidates to
   evaluate include avoiding full-image buffer copies and format conversions,
   reusing scratch storage within one job, tiling suitable pixel operators,
   Accelerate/Metal implementations for proven CPU hot loops, and encoder
   settings. Preserve full-resolution output, correction parity, metadata,
   cancellation cleanup, and the one-full-resolution-RAW-at-a-time memory
   contract. Do not trade export fidelity for speed unless a separately named
   fast-export option is explicitly designed.

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

Run the GPU-vs-CPU preview comparator (comprehensive diagnostic across 2,655
parameter combinations and five test images):

```sh
swift run --package-path native/FilmScanEngine FilmScanPreviewComparator
```

Run the opt-in 500-render latency benchmark:

```sh
RUN_PERFORMANCE_TESTS=1 swift test \
  --package-path native/FilmScanEngine \
  --filter productionRendererBurstBenchmark
```

Run the deterministic release benchmark for protected photographic
adjustments, curves, and color wheels:

```sh
swift run -c release --package-path native/FilmScanEngine \
  FilmScanAdjustmentBenchmark
```

Refresh frozen legacy compatibility fixtures only when intentionally changing
shared behavior:

```sh
.venv/bin/python tests/generate_native_snapshots.py
.venv/bin/python tests/generate_raw_decode_reference.py
```

Run the legacy Python regression suite:

```sh
.venv/bin/python -m unittest discover -v
```

## Logging System

### File output

The native application writes a structured log to `logs/fsc.log` relative to the
project root (`native/FilmScanEngine/Package.swift`). On launch, the app walks
up from the executable path to locate the project root, then creates `logs/` if
it does not already exist. If the project root cannot be found, the app falls
back to `~/Library/Logs/FilmScanConverter/fsc.log`.

All native log files match the `.gitignore` pattern `*.log` and the `logs/`
directory is entirely ignored.

### Sources

Log messages are produced by three independent subsystems that share a single
on-disk output:

| Source | File | Format prefix | Disciplines |
|---|---|---|---|
| Swift `LogFile` | `Logging.swift` | Custom (`[Import]`, `[Decode]`) | Import lifecycle, decode events, errors |
| C bridge `FSC_LOG` | `CLibRawShim.c` | `[FSC-RAW]` | LibRaw init, file open, unpack, dcraw process, memory image, allocation, free, thumbnail extraction. Gated on `#ifdef DEBUG` in release builds. |
| Apple `OSLog` | Various | N/A (system log) | Import, Decode, Export, StillPreview, Signpost categories |

### Timestamp format

- Swift-level messages (`LogFile.write`): `yyyy-MM-dd HH:mm:ss.SSS` (millisecond
  precision).
- C-level messages (`FSC_LOG`): `yyyy-MM-dd HH:mm:ss` (second precision).

Both levels are written to the same log file and are interleaved
chronologically.

### Key log events

| Event | Meaning |
|---|---|
| `Import started` | A batch of files was presented for import. |
| `Import filtered` | Duplicate and unsupported files were removed. |
| `loadSelection started` | A specific file was selected for decode. |
| `Decoding started` | Either standard or RAW decoding began. |
| `Decode complete` | Decoding finished with pixel dimensions and channel count. |
| `Decode failed` | Decoding failed with an error message. |
| `[FSC-RAW] decode_raw_direct start` | The C bridge began a LibRaw decode via the direct (mmap, single-copy) path. |
| `[FSC-RAW] mmap OK` | The RAW file was memory-mapped. |
| `[FSC-RAW] libraw_open_buffer OK` | LibRaw successfully opened the mmap'd data and identified the camera. |
| `[FSC-RAW] params set; unpacking...` | Decode parameters were configured. |
| `[FSC-RAW] libraw_unpack OK; dcraw processing...` | LibRaw unpacked the RAW data. |
| `[FSC-RAW] libraw_dcraw_process OK; building memory image...` | LibRaw finished dcraw processing. |
| `[FSC-RAW] make_mem_image OK` | A memory image was built with its dimensions and type. |
| `[FSC-RAW] decode_raw_direct SUCCESS` | The full decode completed with dimensions, channels, and pixel count. |
| `[FSC-RAW] free_raw_direct` | The LibRaw processed image buffer was freed. |
| `[FSC-RAW] extract_thumbnail start` | Thumbnail extraction began via `libraw_unpack_thumb`. |
| `[FSC-RAW] extract_thumbnail SUCCESS` | The embedded JPEG was extracted with dimensions and byte size. |
| `[FSC-RAW] free_thumbnail` | The thumbnail JPEG copy was freed. |

### Interpreting the log

A healthy import and decode of a single RAW file produces the following sequence
in order:

```
[Import] Import started — N file(s) presented for import
[Import] Import added: <filename>
[Import] Import filtered — accepted=N rejected=0 duplicates=0
[Import] Import added: appending N new files (total will be N)
[Import] loadSelection started: <filename>
[Import] Decoding started: <filename>
[FSC-RAW] extract_thumbnail start: path=<filename>
[FSC-RAW] mmap OK: N bytes
[FSC-RAW] libraw_open_buffer OK: <camera make>
[FSC-RAW] extract_thumbnail SUCCESS: WxH JPEG N bytes
[FSC-RAW] free_thumbnail: 0x... (N bytes)
  (preview appears immediately from embedded JPEG)
[FSC-RAW] decode_raw_direct start: path=<filename> fullRes=0
[FSC-RAW] mmap OK: N bytes
[FSC-RAW] libraw_open_buffer OK: <camera make>
[FSC-RAW] params set; unpacking...
[FSC-RAW] libraw_unpack OK; dcraw processing...
[FSC-RAW] libraw_dcraw_process OK; building memory image...
[FSC-RAW] make_mem_image OK: WxH type=2 bits=16 colors=3
[FSC-RAW] decode_raw_direct SUCCESS: WxH 3ch N pixels cdesc=RGBG
[Decode] RAW decode started: <filename> fullRes=false
[Decode] RAW decode complete: <filename> WxH color=RGBG libraw=0.21.4-Release
[Import] Decode complete: <filename> WxH 3ch
[FSC-RAW] free_raw_direct: 0x... (N pixels)
  (RAW buffer swaps in, preview re-renders)
```

**Warning signs:**
- Duplicate `Import started` / `loadSelection started` for the same files within
  one second indicates a double-import bug.
- A crash immediately after `free_raw_direct` with no further log lines suggests
  a post-decode processing failure (e.g. median computation, preview render).
- Missing `decode_raw_direct SUCCESS` but present `decode_raw_direct FAIL`
  indicates a LibRaw error; the failure message includes the specific LibRaw
  error code.
- Missing `free_raw_direct` for a previously allocated image indicates a memory
  leak in the C bridge.
- `extract_thumbnail FAIL` followed by a successful `decode_raw_direct` is normal
  for RAW files without embedded JPEG previews; the app falls back to the standard
  decode path.
- In release builds, FSC_LOG messages are absent; diagnostics rely on Swift-level
  `[Import]`/`[Decode]` log events and OSLog.

## Development Rules

- Write the compatibility or behavior test before implementing a native stage.
- Require exact pixel equality first. Document any unavoidable tolerance before
  accepting it.
- For native-only features such as curves and color wheels, define and freeze
  the authoritative CPU behavior before implementing the GPU preview or UI.
- Do not add new product features to Python. Limit Python changes to critical
  correctness, data-loss, compatibility, and fixture-tooling fixes.
- Keep live preview explicitly separate from final-quality RAW processing.
- Update this page when the active development step or implemented scope changes.
- Keep the retirement gates in
  [Legacy Python Status And Retirement](../legacy-python.md) aligned with
  actual native capabilities.
- Be aware of float32 precision in the Python pipeline: `cv2.boxPoints` returns
  float32, and `matplotlib.colors.rgb_to_hsv` operates in float32 internally.
  Swift implementations using `Double` (float64) must match precision via
  `Float` casts or accept documented tolerance for intermediate stages.
- The Python `shrink_box` uses `np.where(box==topleft)[0][0]` which does
  element-wise matching (not row-wise). This is benign for the output but
  must be replicated exactly for pixel equivalence.
