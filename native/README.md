# Native macOS Package

This directory contains the Swift package, native application, benchmarks, and
release packager. Product status and priorities are intentionally maintained
elsewhere:

- [Native development status](../docs/development/native-macos.md)
- [Product roadmap](../docs/improvements/MacOS-Native-Roadmap.md)
- [Feature inventory](../docs/features.md)
- [Release runbook](../docs/development/native-release.md)

## Package Structure

`native/FilmScanEngine` provides:

- `FilmScanEngine`: deterministic image, processing, crop, dust-mask, RAW,
  standard-image, and export primitives;
- `FilmScanPreviewRenderer`: the bounded Core Image/Metal still renderer;
- `FilmScanConverterMac`: the primary SwiftUI application;
- `FilmScanRawBenchmark`: compatibility-profile RAW decode benchmark;
- `FilmScanExportBenchmark`: staged production export benchmark with per-run
  output hashing and deletion, plus an opt-in camera-scan determinism mode
  with stage-boundary digests;
- `FilmScanAdjustmentBenchmark`: release-mode preview benchmark with active
  dye crossover, protected color/tone, curves, and color wheels;
- `FilmScanPreviewComparator`: CPU/GPU visual and numerical comparison tool;
- `FilmScanReleaseValidator`: packaged-app contract validator;
- `FilmScanProcessingBenchmark`: focused processing benchmark;
- `FilmScanProfileCalibrator`: offline weighted density-matrix fitter with a
  frame-level held-out validation gate;
- `FilmScanReferenceCalibrator`: offline paired RAF/JPEG/XMP curve fitter used
  for the historical Natural reference curves;
- `FilmScanLookbook`: developer utility for generating preview/comparison
  images from the local RAW corpus.

Compare factory LookRecipe snapshots with a C-41 invert-only column using
the local sample scans:

```sh
swift run --package-path native/FilmScanEngine FilmScanLookbook \
  /tmp/film-scan-color-lookbook
```

The generated `index.html` links rendered JPEGs. These recipes are creative
starting points, not measured stock calibrations. `LookRecipeTests` and
`LookRecipeAppTests` cover recreatability from public sliders, film-base
isolation, apply without image analysis, persistence, and undo.

The package requires macOS 14 or later, Swift 6, and Homebrew LibRaw plus
`pkg-config`. `CLibRawShim`
provides the narrow C/C++ boundary used by Swift. Camera-scan X-Trans keeps
LibRaw 0.21.4's integer arithmetic and overlapping-tile dependence, then runs
independent `2*row+col` wavefront diagonals. Fuji compressed unpack runs
independent strips concurrently through `fuji_decode_loop`. `LIBRAW_FORCE_OPENMP`
stays off. No LibRaw-owned buffer or lifetime is exposed to the application.

## Build And Test

```sh
brew install libraw pkg-config

bash native/test-raw-compatibility.sh
swift test --package-path native/FilmScanEngine --no-parallel
swift build --package-path native/FilmScanEngine \
  --product FilmScanConverterMac
swift run --package-path native/FilmScanEngine FilmScanConverterMac
```

Use `swift run` for development. It does not exercise the normal installed-app
Launch Services path, embedded dependencies, icon, document registration, or
release signature.

## Density-Matrix Calibration

This tool is retained as parked research infrastructure. Do not expand it into
corpus preparation, named-stock fitting, residual LUT generation, or ML work
until the project owner explicitly reactivates that track; the active roadmap
is focused on the photographer-facing core workflow.

Run the synthetic fitter smoke example:

```sh
swift run --package-path native/FilmScanEngine \
  FilmScanProfileCalibrator \
  native/FilmScanEngine/Examples/density-matrix-calibration.synthetic.json \
  /tmp/film-scan-density-calibration-report.json
```

The tool consumes already aligned, base-subtracted BGR density and target log
exposure samples. It fits a regularized 3x3-plus-offset capture transform,
rejects frame leakage between fit and validation partitions, and compares
held-out RMSE with the identity transform. It writes a candidate capture
profile and report but never installs it. The committed example is synthetic,
not a product profile. See the
[calibration contract](../docs/development/density-matrix-calibration.md).

## Packaged-App Validation

Build a self-contained, locally ad-hoc-signed development app and ZIP:

```sh
RELEASE_MODE=local native/package-release.sh
open "dist/Film Scan Converter.app"
```

The packager embeds non-system dynamic libraries, rewrites bundle load paths,
signs in dependency order, embeds licenses/notices and an exact library
manifest, validates the app, creates a metadata-clean ZIP and SHA-256 file,
extracts it, and validates the archived copy. `RELEASE_MODE=public` requires an
exact Developer ID Application identity and notary keychain profile and performs
submission, stapling, and Gatekeeper assessment. Follow the
[release runbook](../docs/development/native-release.md) for notarization,
stapling, Gatekeeper, and clean-machine validation.

## Benchmarks And Diagnostics

For Camera Raw reference comparisons, film-preset trials, and segmented skin RGB
measurements, start with the [color evaluation runbook](../docs/development/color-evaluation.md).
`diagnostics/color-study.py` provides preflight, ordered execution, and guarded
resume using production `FilmScanLookbook` renders. Its historical study stages
still need migration to current recipe names and correction documents; consult
the runbook's compatibility status before treating a run as reproducible.

The [preview-analysis benchmark](../docs/performance/preview-analysis.md)
isolates CPU clipping/tone diagnostics and Darkroom neutral-axis analysis,
including release timing, physical footprint, exact pre-change references, and
Darkroom percentile-sort reuse.

Run the staged 40 MP export benchmark:

```sh
swift build -c release --package-path native/FilmScanEngine \
  --product FilmScanExportBenchmark

native/FilmScanEngine/.build/release/FilmScanExportBenchmark \
  sample-raw /tmp/film-scan-export.json 3 \
  --file=fuji400-fresh/DSCF2833.RAF
```

The default format set is TIFF, JPEG, PNG, and DNG. Use
`--formats=tiff,png`, `--all --limit=10`, or `--frame-percent=2` to vary the
run. Each generated image is hashed and removed immediately; only the JSON
report remains. The report retains the individual samples plus median and
nearest-rank p95 totals, stages, decode substages, packed-pixel bytes, current
and peak physical footprint, reusable bytes, legacy resident-memory checkpoints,
and default-zone live/reserved heap checkpoints after per-sample release.
Physical footprint is the live-memory gate; resident size can include clean
reusable pages. The executable covers engine decode/process/write. Use the
app's correlated signposts in Instruments for deeper settings, classification,
flat-field, queue, destination, cancellation, and UI timing. See the
[40 MP benchmark notes](../docs/performance/40mp-export.md).

Run the camera-scan determinism mode to diagnose a threaded decode candidate:

```sh
native/FilmScanEngine/.build/release/FilmScanExportBenchmark \
  sample-raw /tmp/film-scan-determinism.json 5 \
  --determinism --file=fuji400-fresh/DSCF2833.RAF
```

This repeats full-resolution camera-scan decodes with stage-boundary SHA-256
capture (unpacked mosaic, demosaiced image, processed image, post-ISO image,
Swift image, corrected image, writer-input pixels, output file), writes one
LZW TIFF per repetition, and reports per-boundary digest agreement in pipeline
order. The first disagreeing boundary is the first stage the candidate allowed
to diverge. Each repetition prints all eight full digests plus peak and
post-release physical footprint before final report assembly, preserving
diagnostic evidence if report finalization fails. The mode defaults to five
repetitions and rejects fewer; `--formats` is not accepted in this mode.
`FSC_UNPACK_WORKERS` accepts 1–16 camera-scan unpack workers;
`FSC_XTRANS_WORKERS` accepts 1–8 demosaic workers. `1` selects the respective
serial oracle. Without overrides, each uses the available CPU count up to its
cap; unpack also stops at the number of independent compressed strips. The
unpack cap drops to eight when another camera-scan decode is already active,
including when a larger diagnostic override is requested. The RawPy-compatibility
unpack path remains serial.

Run the full-resolution correction-scenario matrix:

```sh
native/FilmScanEngine/.build/release/FilmScanExportBenchmark \
  sample-raw /tmp/film-scan-corrections.json 3 \
  --corrections --file=fuji400-fresh/DSCF2833.RAF
```

This decodes once per repetition and measures neutral, tone, protected-color,
dye-mixing, and combined correction against the same authoritative image. It
reports scenario passes, correction and writer timing, corrected/writer/output
hashes, physical footprint after decode/processing/write/release, process peak,
and allocator statistics after scenario intermediates are released. One LZW
TIFF per scenario is verified and removed; `--formats` is not accepted in this
mode.

Run the opt-in real-app preview and switching benchmark:

```sh
RUN_APP_PATH_PERFORMANCE_TESTS=1 \
APP_PATH_BENCHMARK_REPETITIONS=3 \
APP_PATH_BENCHMARK_OUTPUT=/tmp/film-scan-app-path.json \
CLANG_MODULE_CACHE_PATH=/tmp/film-scan-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/film-scan-swiftpm-cache \
swift test --disable-sandbox -c release \
  --package-path native/FilmScanEngine --no-parallel \
  --filter AppPathPerformanceTests
```

This uses the local RAF corpus, emits a JSON latency/memory report, and writes
no exports. Each phase cancels selection work, waits for model release, and
removes its isolated preferences before the next phase. Configured cache depths
2, 8, and 32 report initial lookahead population, source tiers, logical bytes,
fill latency, and physical footprint before fill, after lookahead, and after
release; these are not full-capacity or settled-speculation samples. Separate
cases warm two full-sensor corrected previews and their statistics, measure
retained revisits and 1,000 viewport updates with decode/correction/statistics/
cache-hit counters, and measure
repeated switching with a saturated two-session cache and an uncached neighbour.
That last case records publication latency, time through background drain, and
speculative scheduler submissions. Timings measure app-model publication, not
native input or screen presentation; three default repetitions do not estimate
tail latency. Switch waits poll every 5 ms, limiting timing resolution. The
retained cases require two full source/renderer/display sessions to fit the
machine's default preview budget (typically at least 16 GiB RAM for two 40 MP
scans); insufficient budget can cause the full-preview wait to time out.

Run the real-RAW preview-scale probe after changing render resolution, gesture
scheduling, or selected-session memory ownership:

```sh
RUN_PREVIEW_SCALE_BENCHMARK=1 \
FSC_PREVIEW_SCALE_OUTPUT=/tmp/fsc-preview-scale.json \
CLANG_MODULE_CACHE_PATH=/tmp/fsc-preview-scale-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/fsc-preview-scale-swift \
swift test --disable-sandbox -c release \
  --package-path native/FilmScanEngine --jobs 2 --no-parallel \
  --filter PreviewScalePerformanceTests
```

It measures the same real RAF at draft, inspect, and full-sensor tiers, forces
each Core Image result through the app's bounded statistics consumer, and
compares the full source with the retained 2048px continuous-edit proxy. The
[measurement note](../docs/performance/preview-scale-2026-09-14.md) defines the
scope and quality boundary.

Run the opt-in real-app sequential export and cancellation benchmark:

```sh
RUN_APP_PATH_EXPORT_PERFORMANCE_TESTS=1 \
APP_PATH_EXPORT_BENCHMARK_OUTPUT=/tmp/film-scan-app-path-export.json \
CLANG_MODULE_CACHE_PATH=/tmp/film-scan-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/film-scan-swiftpm-cache \
swift test --disable-sandbox -c release \
  --package-path native/FilmScanEngine --no-parallel \
  --filter AppPathExportPerformanceTests
```

This runs ten production app-path TIFF jobs, appending duplicate source jobs
when fewer than ten local RAFs are available, and then measures cancellation
during the first decode of a second queue. It records queue completion timing,
Mach physical footprint, post-model-release memory, status/progress state, and
artifact cleanup. Completed outputs are removed as the benchmark observes each
job; only the requested JSON report remains.

Build the corpus-wide RAW benchmark and run the synthetic preview tools:

```sh
swift build -c release --package-path native/FilmScanEngine \
  --product FilmScanRawBenchmark

swift run -c release --package-path native/FilmScanEngine \
  FilmScanAdjustmentBenchmark

swift run --package-path native/FilmScanEngine FilmScanPreviewComparator
```

Run the opt-in burst benchmark:

```sh
RUN_PERFORMANCE_TESTS=1 swift test \
  --package-path native/FilmScanEngine \
  --filter productionRendererBurstBenchmark
```

## Fixtures

Swift tests consume committed `.npy` and standard-image fixtures. When the
required files in the untracked `sample-raw/` corpus exist, RAW tests also
verify five RawPy-compatible half-size RAF decodes and one full-resolution
decode against recorded hashes. The camera-scan byte-identity fixture
(`camera_scan_decode_reference.json`) separately pins the full-resolution
`rawTherapeeCameraScan` decode of `fuji400-fresh/DSCF2833.RAF`, including
wavefront X-Trans and parallel Fuji unpack oracles. The X-T5 regression trio
additionally guards camera-scan previews against leaked X-Trans mosaic pixels.
Default corpus-dependent regressions are explicitly disabled unless all files
they need are present. The opt-in `RepresentativeRollWorkflowTests` instead
requires its three named Fuji 400 files once enabled; see the
[test guide](../tests/README.md#native-viewport-and-roll-workflow).
The corpus may be organized recursively by film stock. See
[Reference Negative Calibration](../docs/development/reference-negative-calibration.md)
for paired-triplet naming, fitting, and held-out stock-profile gates.

Refresh compatibility fixtures only when intentionally changing a shared
legacy contract:

```sh
.venv/bin/python tests/generate_native_snapshots.py
.venv/bin/python tests/generate_raw_decode_reference.py
```

New native-only processing behavior must define a deterministic authoritative
Swift CPU contract. Do not backport it to Python merely to create a fixture.

## Implementation Contracts

- Keep interactive previews bounded and latest-value-wins.
- Use explicit image contracts: standard-image browsing starts with a 1000px
  display source; camera RAW browsing starts with a colour-accurate ~640px
  demosaiced draft, upgrades the selected file to a ~4000px inspect preview
  then a 1-pass full-sensor preview. Neighbour files first get a 3200px
  preview; up to two then get full-sensor previews when memory permits.
  A 256px analysis source drives classification. Export owns an
  independent three-pass full-resolution decode. The selected file may keep
  that last three-pass buffer for settings-only re-export and must drop it on
  selection change.
- A selected full-sensor RAW retains one 2048px continuous-edit source and GPU
  renderer. Supported active point-control gestures publish that raster at the
  full logical document size; gesture release must queue exact current
  parameters against the full source. CPU fallbacks use bounded, cached proxy
  preparation too; 100% detail and export retain their full source.
  Zoomed GPU gestures reuse this proxy for the background overview while the
  visible detail comes from the full source. Only the completed full-source
  refinement can enter the retained corrected-raster cache.
- Keep lookahead preview-only, LRU, and bounded by both file count and bytes.
  Selecting a cached 3200px lookahead preview skips the inspect decode and
  starts the selected-file full-sensor upgrade. Sidebar thumbnails and repeated
  capture detection still use embedded JPEGs; the main RAW canvas does not.
  Retain completed full-resolution 1-pass previews and their last corrected
  rasters across selection changes. The cache budget is one eighth of RAM,
  capped at 3 GiB (2 GiB on 16 GiB machines), including source, renderer backing,
  and display rasters. Reserve display space before admitting speculative work;
  speculation must not evict existing entries. Evict least-recently-used,
  unselected entries at either the byte or file-count limit. A selected image
  alone may exceed the budget; memory pressure drops all unselected entries
  and suspends speculation until pressure clears. **Load RAW Preview** requests
  full-sensor detail directly and cancels any in-flight inspect decode through
  the shared gate. Automatic browsing retains the normal inspect/full progression.
- Keep the still image, dust mask, and crop/straighten/perspective editors in
  one native viewport transform. Original comparison must preserve its pan and
  magnification, and selection changes must return to a predictable Fit state.
- Define 100% against the pixels in the current preview, which become sensor
  pixels after the full-res upgrade, not the three-pass export source. Do not
  label inspect versus full-res on the canvas; keep the embedded-JPEG warning
  when RAW colour is unavailable.
- `FilmBase` owns invert defaults. `LookRecipe` assigns public sliders, curves,
  and wheels without image analysis or changes to film base, invert IDs, measured
  calibration, or geometry. Factory looks are creative snapshots. The former
  adaptive/Kodachrome-like look path has been removed. Test current recipes with
  `LookRecipeTests`, `LookRecipeAppTests`, and `PresetWorkflowTests`.
  A look copied onto an uninitialized destination persists as a pending look;
  first decode resolves its film base before applying the copied controls.
  Intentionally saved Original frames keep Original. Preview, export, contact
  sheets, Undo/Redo, and relaunch must preserve that distinction.
- New neutral edits use photographic tone version 4. Highlights/Shadows affect
  broad regions, Whites/Blacks focus on the respective ends without moving black
  or white, and the grading Shadow Floor/Midtone Level/Highlight Ceiling controls
  independently change output levels. Built-in looks remain pinned to version 2
  to preserve their starting appearance; saved versions 1–3 retain their rendering
  until edited or explicitly upgraded. Editing a version 2/3 Highlights, Shadows,
  Whites, Blacks, or grading level promotes it to version 4 in the same undo step.
  Version 1 retains its explicit, undoable upgrade and decoded paper response.
  The [original tone contract](../docs/development/photographic-tone-controls-2026-09-22.md)
  and [ordinary-response study](../docs/development/slider-response-study-2026-09-24.md)
  record earlier behavior and validation. Version 2 density analysis uses the
  immutable 256px sensor frame so manual crops stay GPU eligible and do not
  remeter color. Older builds reject saved version-4 edits.
- Correction clipboard and named-preset writes use schema version 2. Version 1
  documents migrate to public-control recipes; legacy inversion/calibration is
  not transferred. The first mutation of a version 1 preset library backs up its
  original bytes. Unknown versions must fail without overwriting the library.
- Treat `FilmDyeMixingParameters` as a neutral-preserving, linear-light film
  response operator, not a display white-balance replacement. Apply it after
  inversion and before semantic tone/protected color, curves, and grading in
  the basic, power-law, physical density-print, and density paths. Keep its CPU and Core Image kernels
  in parity, and keep the exact-neutral fast path bit-for-bit unchanged.
- User film-stock profiles persist exponent, dye-mixing, density-response, and
  display-rendering priors. Preserve the recorded provenance of existing Natural
  curves and Darkroom stock matrices. Further named-stock fitting and capture
  calibration are parked until the owner reactivates them; fitted candidates
  still need held-out evidence before promotion.
- Keep edit history session-local and isolated by standardized source path.
  Coalesce each slider, curve, color-wheel, and perspective drag into one
  history entry; persist the restored current state but start with empty
  transient history after relaunch. Look application and Reset Adjustments must
  remain reversible without resetting film base, calibration, crop, or orientation.
- A failed per-file settings read must not let subsequent edits overwrite the
  unreadable or unsupported document. Saving retries only after that document
  can be read or has been removed. Recovered files outside the current session
  must survive every later save; session values and edited markers take precedence
  for files edited during recovery.
- Treat manual film-frame geometry as a persisted, validated clockwise
  four-corner quadrilateral. Its reticle/loupe editor may softly snap either
  incident edge parallel to its opposite edge, but must preserve an explicit
  free-drag path. Optional known frame proportions determine the rectified output
  ratio while retaining estimated pixel area; absent ratios preserve old sizing.
  Ratios precede rotation/straightening and remain local during look transfer.
  Grid lines project equal output divisions into source space. Dragging preserves
  the initial grab offset, snap distances use screen units, and keyboard nudges
  use source pixels independently of display zoom. The normalized canvas crop
  depends on the perspective result.
  Clearing manual crop preserves perspective; changing or clearing perspective
  invalidates the dependent manual crop. Preview, dust-overlay alignment,
  density flat field, and export must use the same CPU perspective warp; this corrects one
  planar frame and is not a lens-distortion model.
- Manual-crop ratios constrain editing in full-output canvas coordinates after
  upstream geometry. The normalized rectangle remains the processing authority;
  the saved ratio is an editing constraint and does not add export padding.
  Preserve each destination's ratio during look transfer, and include it in
  edit history. Old settings default to Free.
- Resolve each two-point straighten guide against its nearest horizontal or
  vertical axis, then apply the persisted angle after quarter-turn rotation and
  flip. Apply the simple normalized canvas crop after that expanded rotation.
  Preview, full-resolution dimension prediction, flat field, dust overlay, and
  export must preserve this geometry order.
- The Metal path supports manual crops with the CPU's outward whole-pixel
  bounds after quarter turns and flip. Darkroom/power-law cases whose analysis
  depends on cropped pixels and exact Original/crop-only packing remain CPU
  fallbacks. While the Crop tool is active, preview the full post-straighten
  canvas so the next drag replaces the existing crop.
- Density-print previews whose analyzed channel log span is below 0.001 use
  the authoritative CPU fallback. This avoids amplification of Float cancellation
  on flat or nearly flat scans. The renderer checks source-dependent support on
  the rendering worker; Original comparison bypasses density analysis.
- Treat the Core Image/Metal renderer as the primary interactive development
  path on supported MacBook Pro hardware. Keep CPU rendering correct for
  deterministic tests, CI/headless runs, export/reference behavior, and fallback
  paths that are not GPU-integrated yet.
- Schedule draft/detail/full RAW and export decoding through the shared priority
  queue. Propagate cancellation into safe native decoder boundaries. ImageIO
  calls remain synchronous.
- Keep full-resolution RAW export one-file-at-a-time. Retain the selected
  file's last three-pass decode for settings-only re-export; drop it on
  selection change. Do not prefetch file N+1 or keep a roll-sized decode cache.
- Contact-sheet PDFs snapshot selected/all settings and stack membership at
  start, preserve import order, and use corrected demosaiced previews bounded
  to 1000px. Decode captures sequentially through the shared RAW gate; never
  populate the authoritative export cache. Stage the complete PDF and commit
  only after all tiles succeed, with cancellation and collision-safe naming.
- Give export priority over speculative lookahead work and check cancellation
  between decode, correction, geometry, and write stages.
- Preserve PNG's staged commit, collision-safe naming, and destination cleanup
  on export failure for every format.
- Compare performance only across identical profiles, stage sets, hardware, and
  quality contracts.
- Keep product claims in `docs/features.md`, current evidence in
  `docs/development/native-macos.md`, and priority in the roadmap.

## Live Camera Scope

Live preview works only when macOS exposes the camera or capture adapter as an
AVFoundation video device. It is a fast preview path; final stills use the
16-bit import and export pipeline. Vendor-specific tethering is not active
roadmap work.

### Current preview retention and work reuse

Navigation retains several full-sensor decodes plus their completed corrected
rasters, bounded by RAM and LRU limits. Settled previews use a complete raster:
panning and zooming only change the native viewport, without correction work or
histogram publication. Completed statistics belong to their immutable corrected
raster and are reused on cached revisits. A gesture whose pixels are already
complete refreshes delayed statistics without another correction; proxy and
viewport edits still require exact full-source refinement. Active edits can use
an overview plus a visible region, then settle to an exact complete image.
Source, settings, Original, and flat-field changes invalidate display reuse.

On machines with at least 16 GiB RAM, the cancellable priority scheduler permits
one foreground and one speculative decode concurrently, with at most two workers
and at most one speculative worker. Export preempts speculation. Adjustment
gestures preserve background progress. CPU preparation still reuses geometry and
Darkroom analysis; revision-bound statistics follow publication asynchronously.
See the [earlier measurements](../docs/performance/viewport-and-work-reuse-2026-09-16.md)
for the preceding viewport-region implementation.
