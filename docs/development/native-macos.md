# Native macOS Development

This page is the authoritative status for the Swift/macOS rewrite. It describes
what works now, the current development step, and the order of upcoming work.
The detailed [macOS native roadmap](../improvements/MacOS-Native-Roadmap.md) is
the design reference, not a statement that every listed item is implemented.

**Last updated:** 2026-06-16 (160 tests; startup film-kind classification applies RawTherapee color-negative/B&W presets or slide mode automatically for new imports; Export All now lazily decodes, classifies, processes, and writes unloaded batch files without retaining every full-resolution image)

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
Those gates include the remaining crop/perspective/dust
workflow, settings migration, fixture independence, and release validation.
Native export is complete.

## Current Development Step

**Active step: film-specific camera-scan track. RawTherapee-compatible film negative power-law inversion is complete with 20%-border-cut median sampling, neutral middle-gray calibration, adopted presets (Color Negative and Black & White), CPU/GPU/Metal processing parity, SwiftUI controls, and automatic startup classification for new imports. Slice A (capture normalization), Slice B (linear-capture diagnostics), and the first engine-only Slice C manual rebate/roll-reuse API are complete as standalone engine APIs.**
TIFF, JPEG, PNG, and DNG export is complete with individual and memory-bounded batch workflows, cancellation, partial-file cleanup, and 19 focused tests. The native app can now produce processed output files across all four formats from the full-resolution decoded image with applied corrections, frame, and aspect ratio.

## Next Step

**Continue from the completed startup classification into Slice C UI/manual-region wiring or Slice D automatic rebate estimation, building on the now-operational power-law inversion as a preview-compatible front-end. Then add base density and color space conversion, followed by flat-field calibration.**
The app now starts new files in color negative, B&W negative, or slide mode from deterministic proxy statistics without overwriting existing per-file settings. The engine also computes robust median/trimmed-mean transmittance and density from a user-selected rebate rectangle, persists measured roll base in a Codable roll profile, and resolves base-density precedence. Next, expose the manual region picker in the app or implement automatic rebate candidates without silently overriding stronger roll/manual measurements.

## Progress

| Area | Status | Current result |
|---|---|---|
| Phase 0: regression gate | In progress | Swift tests consume frozen Python-generated `.npy` fixtures and compact RAW hash manifests. Standard decode fixtures cover 8-bit PNG, grayscale PNG, BMP, JPEG, and 16-bit TIFF. Five half-size RAF decodes and one full-resolution RAF decode require exact SHA-256 equality with RawPy when the local `sample-raw` corpus is present. The full intermediate-stage and parameter-grid corpus is not complete. |
| Phase 1: processing engine | In progress | `FilmScanEngine` decodes standard images and RAW files, with pixel-equivalent rotate, flip, frame, and aspect-ratio helpers. Threshold generation, white balance, saturation, exposure, histogram equalisation, `shrink_box` coordinate math, overall/per-channel RGB curves (piecewise-linear 65536-entry LUTs), and highlight/midtone/shadow color wheels (tonal masks with luminance preservation) are complete with exact or documented-tolerance equivalence. RawTherapee-compatible film negative power-law inversion is complete: per-channel exponent model (`output = multiplier × pixel^-(greenExp×ratio)`), auto-calibration via 20%-border-cut channel medians to neutral middle gray, Color Negative and Black & White presets matching RawTherapee's defaults, full CPU (Double), GPU-equivalent (Float), and Metal CIKernel processing parity, plus deterministic startup classification for color negative, B&W negative, and slide scans. The film-specific track has three complete standalone engine APIs: per-channel black-level correction, flat-field normalization, optical-density conversion, and manual base-density subtraction (Slice A); linear-capture diagnostics with per-channel min/max, clipping fractions, source-kind/bit-depth metadata, and deterministic warnings for nonlinear/unsuitable input (Slice B); and manual rebate base-density measurement plus roll-profile reuse and precedence resolution (Slice C). Contour detection, perspective warp, dust detection, automatic rebate estimation, UI region picking, and density-pipeline integration are deferred. |
| Phase 2: accelerated rendering | In progress | Live camera preview uses a Metal-backed Core Image context. Still-file correction uploads one bounded 16-bit proxy per selection, applies the current correction controls in one custom GPU kernel, and keeps only one in-flight render plus the newest pending snapshot. The kernel includes RawTherapee-compatible film negative power-law inversion, curve LUT sampling (256×256 8-bit texture), and three-way color wheel tonal adjustments. The production renderer is verified against the authoritative CPU path across 2,655 comparisons with zero failures and a maximum difference of 2/255. The latest 500-change current-pipeline benchmark measured 3.74 ms p95 at 1080×720 after bounded LUT caching; the app now uses a 640-pixel maximum interactive proxy, which contains about 2.85× fewer pixels than the former 1080-pixel proxy. Render instrumentation and scheduling contract tests are deployed. A direct Metal-backed preview surface and idle authoritative rendering remain. |
| Phase 3: SwiftUI application | Interactive correction + export workflow | The app accepts supported files by drag and drop, decodes standard images and RAW files, auto-initializes new files to color negative, B&W negative, or slide mode, and provides per-file film mode, film negative preset (Off/Color Negative/B&W) and per-channel ratio/exp sliders, orientation, white balance, exposure, shadows, highlights, saturation, curves, color wheels, reset, and original/corrected comparison controls. An export section supports TIFF, JPEG (configurable quality), PNG, and DNG output with frame percentage, aspect-ratio presets, TIFF LZW compression, destination folder selection, per-file error reporting, and individual plus batch-all export. Export All decodes and processes unloaded files on demand instead of requiring every batch member to be selected first or retained in a full-resolution cache. The two most recent decoded/proxy/renderer sessions are cached for immediate back-and-forth switching. Slider and wheel bindings remain live during continuous drags; end-to-end latency still requires real-file verification. |
| Phase 4: performance and polish | Early measurement | CI builds and tests the current native package. The representative RAW decode and quality benchmark is complete; packaging, UI snapshots, and release work remain. |

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
- individual and batch-all export with actor-based batch parallelism,
  memory-bounded concurrency, cancellation propagation, error-per-file
  reporting, and partial-file cleanup.

Film-specific camera-scan processing now has a separate staged track based on
the [film-processing research brief](../film-processing-research.md). The
RawTherapee-compatible power-law inversion is complete and operational as
a preview-compatible front-end. Upcoming phases add film base density and color
space conversion, then flat-field calibration (geometry + density-domain
normalization). The first engine-only slice (capture normalization + density
primitives) and second engine-only slice (linear-capture diagnostics) remain
complete, and the first Slice C engine API now measures manual rebate base
density and persists roll-level reuse metadata. Upcoming slices add UI region
picking, automatic rebate estimation, generic C-41 rendering, capture profiles,
per-stock inverse density curves, fitted matrices, and optional residual LUTs.
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
- A narrow C module boundary around thread-safe LibRaw, returning owned 16-bit
  BGR buffers with no LibRaw lifetime exposed to Swift.
- Exact RawPy-equivalent half-size decoding for all five representative X-T5
  RAF files and exact full-resolution decoding for one representative RAF.
- A reproducible [native RAW decode and quality benchmark](native-raw-benchmark.md)
  proving exact decoded pixels for all five RAFs at half and full resolution.
- Background RAW decoding and preview through the same engine-buffer path used
  by standard images.
- A bounded 640-pixel correction preview proxy that rerenders verified engine
  corrections in the background without changing the full decoded source. This
  CPU path is currently suitable only as an idle correctness preview, not
  continuous real-time interaction.
- A bounded two-session decoded/proxy/renderer cache that makes switching back
  and forth between recently viewed files immediate without allowing memory use
  to grow with the imported-file list.
- A reusable Core Image/Metal still-preview renderer that uploads one bounded
  16-bit proxy per selection, disables implicit working-space conversion, and
  fuses film negative power-law inversion, grayscale, white balance, tone, HSV
  saturation, curves, and color wheels into one GPU color kernel. The latest
  500-change 1080×720 runtime benchmark measured 2.73 ms median and 3.74 ms p95
  kernel-plus-`CGImage` render latency on the development machine.
- Bounded latest-value-wins still-preview scheduling with at most one render in
  flight and one newest pending parameter snapshot.
- Display-rate coalescing with a 17 ms inter-frame delay, capping renders at
  ~60 Hz and preventing render backlog during rapid slider interaction.
  Verified by scheduling contract tests (coalescing, latest-value-wins,
  cancellation, bounded backlog) and a 500-update production-renderer benchmark
  including curves and color wheels (1080×720 proxy, 3.74 ms p95 in the latest
  local run).
- Per-file, session-scoped SwiftUI correction controls for film mode,
  orientation, temperature, tint, gamma, shadows, highlights, and saturation,
  plus reset and original/corrected comparison.
- Draggable shadow, midtone, and highlight color wheels with hue mapped around
  the wheel, strength mapped from center to edge, position markers, and
  double-click reset.
- Film-mode-aware inspector states: Original mode explicitly disables all
  corrections, while B&W mode keeps tone controls available and disables color,
  curves, and color wheels instead of presenting controls that processing
  ignores.
- A piecewise-linear curves graph that displays the same interpolation used by
  the authoritative engine and GPU LUT.
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
- Standalone film-negative capture normalization and density-domain primitives:
  per-channel BGR black levels, matched flat-field normalization, safe
  transmittance clamping, optical-density conversion, and manual base-density
  subtraction. Tests verify known ratios, clipping behavior, matched-exposure
  invariance, rebate-zero behavior, and the combined first-slice pipeline.
- RawTherapee-compatible film negative power-law inversion with auto-calibration
  via 20%-border-cut channel medians to neutral middle gray. Per-channel exponent model:
  `output = multiplier × pixel^-(greenExp × ratio)`. Adopted presets matching
  RawTherapee's `Film Negative.pp3` (RedRatio=1.36, GreenExp=1.5, BlueRatio=0.86
  for color negative) and `Film Negative - Black and White.pp3` (all ratios=1.0).
  Full processing parity across CPU (Double), GPU-equivalent (Float), and Metal
  CIKernel paths. SwiftUI controls with preset picker (Off / Color Negative /
  Black & White) and per-channel ratio/exponent sliders showing computed exponents
  and measured medians. 4 processing tests verify inversion direction, multiplier
  calibration, deep-shadow regression prevention, and GPU-CPU equivalence.
- Automatic startup classification for new imports: low-chroma scans initialize
  as B&W negative with the RawTherapee B&W preset, orange-mask channel medians
  initialize as color negative with the RawTherapee color-negative preset, and
  remaining positive-looking scans initialize as slide. Existing per-file
  settings are preserved and never overwritten by classification.
- Linear-capture diagnostic report (engine-only): per-channel minimum and
  maximum values, low/high clipping fractions with 0.1% warning threshold,
  source-kind and bit-depth metadata, and deterministic warnings for 8-bit input,
  lossy source (JPEG), clipped channels, missing flat field, and explicitly
  marked nonlinear input. Codable report with 18 synthetic tests covering 1- and
  3-channel images, channel isolation, warning thresholds, and JSON round-trips.
  98.9% line coverage; only the bit-depth precondition trap uncovered.
- Optional AVFoundation live camera preview.
- GPU-backed live preview inversion, exposure, and saturation controls.
- Late-frame dropping and a 20 FPS processing throttle.
- Camera permission metadata embedded in the executable.
- macOS CI that runs Swift tests and builds the app.
- Legacy Python CI that protects compatibility behavior and fixture tooling.
- Native export to TIFF, JPEG, PNG, and DNG with per-format options (JPEG
  quality, TIFF LZW compression), frame-percent border, and aspect-ratio presets.
- Individual and batch-all export from the full-resolution decoded image with
  applied corrections, background processing, per-file destination,
  error-per-file reporting, and partial-file cleanup. The app-level Export All
  path lazily decodes, classifies, processes, and writes unloaded files one at a
  time so a large import list does not require retaining every 40MP RAW decode
  in memory.

## Important Limitations

- Standard images with alpha channels are rejected because the current
  processing pipeline supports grayscale and three-channel BGR buffers.
- Exact standard-decode equivalence is currently locked for the committed PNG,
  BMP, and TIFF fixtures. JPEG is locked to the documented tolerance above.
  Broader real-file coverage, including embedded color profiles and orientation
  metadata, remains to be added to the frozen corpus.
- The native engine still lacks contour/crop detection, perspective warp, dust
  detection/inpainting. These are the main remaining
  replacement gates.
- Interactive previews do not yet integrate histogram equalisation, film-base
  detection, crop detection, perspective correction, dust removal, or
  persistence across launches. They are suitable for evaluating the current
  correction interaction and loaded-file flow, not final output.
- The new density-domain film-negative API is not yet connected to the
  interactive preview or export pipeline. The power-law film negative inversion
  (RawTherapee-compatible) now serves as the primary inversion front-end for
  color and B&W negative films, with auto-calibration from image medians. The
  density-domain primitives (capture normalization, optical density, base
  subtraction) are complete as standalone APIs but require a matched flat field
  and supplied base density. Import diagnostics (Slice B, complete as engine
  API), and manual rebate/roll-reuse base measurement (Slice C, complete as an
  engine API) remain separate from the interactive workflow. Rebate auto-detection,
  generic C-41 rendering, and stored capture profiles remain roadmap work.
- Still-image slider bindings and the initial GPU correction renderer are
  implemented with bounded latest-value-wins scheduling and display-rate
  coalescing (17 ms inter-frame delay). The actual Core Image renderer is
  verified against the authoritative CPU path across 2,655 comparisons with a
  maximum difference of 2/255. Its latest current-pipeline benchmark measured
  3.74 ms p95 at
  1080×720. A direct Metal-backed preview surface and idle authoritative
  rendering remain. See the
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
- The Python application is maintenance-only legacy code, but remains the only
  complete historical crop/perspective/dust workflow until the retirement gates
  are complete.

The native test suite currently contains **160 tests** across 14 test files,
all passing in the latest local run.

## Completed Native Features (newly added)

- TIFF/JPEG/PNG/DNG export contract with individual and lazy batch-all
  workflows. TIFF exports 16-bit deep with optional LZW compression; JPEG
  exports 8-bit with configurable quality; PNG exports 16-bit lossless; DNG
  produces a valid TIFF container with DNG-specific IFD tags for processed
  16-bit RGB output, explicitly labelled as processed rather than camera RAW.
- ExportManager actor with sequential and parallel (`exportBatch`) modes,
  cancellation propagation, per-file error reporting, and partial-file cleanup
  on failure. Memory-bounded concurrency heuristic based on system physical
  memory and active processor count.
- Export inspector section in the SwiftUI UI: format picker, JPEG quality
  slider, TIFF compression picker, frame-percent slider, aspect-ratio preset
  picker, destination folder selector with system open panel, Export Selected
  and Export All buttons, determinate progress bar, and expandable per-file
  error display. Export All decodes unloaded files on demand and does not retain
  an unbounded full-resolution decoded-image dictionary.
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
- GPU-model-versus-CPU equivalence verified for curves, color wheels, and both
  combined. Direct Core Image renderer comparison covers 2,655 cases with zero
  failures and a maximum difference of 2/255.
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
8. ~~Implement TIFF/JPEG/PNG export and the defined processed-RGB DNG contract,
   including metadata, round-trip, cancellation, and batch-export tests.~~ Done.
   19 export tests covering all four formats, round-trip decode, batch
   parallelism, cancellation, frame/aspect ratio, and JSON coding.
9. Continue the film-specific camera-scan track from the completed engine-only
   manual/rebate base selection and roll-level reuse API toward UI region
   picking, automatic rebate estimation, and a generic C-41 density-to-display
   render; keep each stage separate and testable. Slice A (capture
   normalization), Slice B (linear-capture diagnostics), and the first Slice C
   engine API are complete as standalone engine APIs. RawTherapee-compatible
   film negative power-law inversion is complete and operational as a
   preview-compatible front-end with middle-gray auto-calibration, presets, and
   CPU/GPU/Metal parity.
10. Implement film base density + color space conversion (Phase 2 of film
    negative track) followed by flat-field calibration (Phase 3: geometry +
    density-domain normalization).
11. Port contour detection and crop box computation (requires OpenCV C++ interop
    for `findContours` + `minAreaRect`).
12. Port perspective warp (DLT homography solve + bilinear warp).
13. Port dust detection and Telea FMM inpainting (requires OpenCV interop or
    custom Metal kernel).
14. Expand the frozen corpus to cover intermediate stages and parameter-grid
    variants.
15. ~~Connect completed engine stages to the SwiftUI preview panel.~~ Initial
    interactive correction workflow complete; finish real-file latency
    verification, then expand it as new engine stages land.

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
| C bridge `FSC_LOG` | `CLibRawShim.c` | `[FSC-RAW]` | LibRaw init, file open, unpack, dcraw process, memory image, allocation, free |
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
| `[FSC-RAW] decode_raw start` | The C bridge began a LibRaw decode. |
| `[FSC-RAW] libraw_open_file OK` | LibRaw successfully opened and identified the file. |
| `[FSC-RAW] params set; unpacking...` | Decode parameters were configured. |
| `[FSC-RAW] libraw_unpack OK; dcraw processing...` | LibRaw unpacked the RAW data. |
| `[FSC-RAW] libraw_dcraw_process OK; building memory image...` | LibRaw finished dcraw processing. |
| `[FSC-RAW] make_mem_image OK` | A memory image was built with its dimensions and type. |
| `[FSC-RAW] allocating N bytes` | The Swift-side pixel buffer was allocated. |
| `[FSC-RAW] decode_raw SUCCESS` | The full decode completed with dimensions, channels, and pixel count. |
| `[FSC-RAW] free_raw_image` | The pixel buffer was freed. |

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
[FSC-RAW] decode_raw start: path=<filename> fullRes=0
[FSC-RAW] libraw_init OK
[FSC-RAW] libraw_open_file OK: <camera make>
[FSC-RAW] params set; unpacking...
[FSC-RAW] libraw_unpack OK; dcraw processing...
[FSC-RAW] libraw_dcraw_process OK; building memory image...
[FSC-RAW] make_mem_image OK: WxH type=2 bits=16 colors=3
[FSC-RAW] allocating N bytes for N pixels
[FSC-RAW] decode_raw SUCCESS: WxH 3ch N pixels cdesc=RGBG
[Decode] RAW decode started: <filename> fullRes=false
[Decode] RAW decode complete: <filename> WxH color=RGBG libraw=0.21.4-Release
[Import] Decode complete: <filename> WxH 3ch
[FSC-RAW] free_raw_image: 0x... (N pixels)
```

**Warning signs:**
- Duplicate `Import started` / `loadSelection started` for the same files within
  one second indicates a double-import bug.
- A crash immediately after `free_raw_image` with no further log lines suggests
  a post-decode processing failure (e.g. median computation, preview render).
- Missing `decode_raw SUCCESS` but present `decode_raw FAIL` indicates a LibRaw
  error; the failure message includes the specific LibRaw error code.
- Missing `free_raw_image` for a previously allocated image indicates a memory
  leak in the C bridge.

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
