# Native macOS Development Status

This is the authoritative statement of what the native application does, what
blocks a high-quality public release, and what is being worked on now. Use the
[roadmap](../improvements/MacOS-Native-Roadmap.md) for priority and scope, the
[feature inventory](../features.md) for user-visible behavior, and the
[40 MP benchmark](../performance/40mp-export.md) for detailed measurements.

**Last verified:** 2026-07-17 against the current working tree. The native test
suite contains 395 tests across 28 files. Some representative-RAW tests require
the untracked local `sample-raw/` corpus and are explicitly disabled when it is
absent.

## Release Position

The Swift/SwiftUI application is the primary product and the only destination
for new functionality. It is ready for an explicitly labeled, ad-hoc-signed,
Apple Silicon technical beta on macOS 14 or later. It is not yet an
Apple-notarized general release.

The technical beta boundary is intentionally smaller than the high-quality
first-release standard below. Undo/redo, a deeper representative roll pass,
Developer ID notarization, and independent-Mac validation remain important,
but are disclosed beta limitations rather than reasons to withhold useful
open-source software.

Stock-specific look learning and calibration are not part of the active plan.
The existing generic controls, profile seams, fitter, and research notes remain
available, but no further corpus preparation, named-stock fitting, or ML work
should begin until the project owner explicitly reactivates that track.

## Current Work

The bounded 40 MP measurement cycle and beta packaging/output correctness work
are complete. The still-preview viewport has native pan/pinch navigation,
Fit/step/100% commands, shared image and editing-overlay transforms,
viewport-stable comparison, and explicit preview-source status. Next, use beta
feedback and representative images to prioritize undo/redo, roll workflow, and
performance work. Do not start another broad performance rewrite or divert
into stock-look calibration without measured evidence.

The current measurement evidence is:

- 1000px RAW embedded and standard-image previews are the default interactive
  sources; selected RAWs can explicitly switch to a 2400px demosaiced preview;
- lookahead extracts preview thumbnails and never starts speculative full RAW decodes;
- app-path signposts cover selection-to-first-corrected-paint, preview extraction,
  conversion, analysis, and export from queue wait through cleanup;
- export cancellation now stops speculative lookahead decoding, checks each
  decode/correction/geometry boundary before advancing, and reports every
  unstarted batch item as cancelled;
- the release export benchmark measures decode, correction, geometry, packing,
  writer finalization, packed/output bytes and hashes, current resident and
  reusable bytes, and current/peak physical footprint;
- one 40.19 MP RAF-to-TIFF smoke run took 27.51 seconds and reached a 1.20 GB
  process-lifetime peak RSS;
- 19.71 of 21.68 decode seconds were spent in final-quality three-pass X-Trans
  demosaic;
- parallel full-resolution power-law correction reduced that measured stage
  from 3.685 seconds to a 0.926-second median with identical TIFF bytes and
  SHA-256, reducing median total export to 24.874 seconds.
- the repeated format baseline is complete: three TIFF/JPEG/PNG/DNG runs for
  `DSCF0669.RAF` plus three TIFF runs for `DSCF0718.RAF` and `DSCF0729.RAF`;
  final-quality decode remained the dominant stage across the 16.72–27.41
  second median total range, and all 18 temporary outputs were removed.
- the corrected ten-file sequential TIFF confirmation completed with every
  output removed and no sustained live-memory growth: post-release physical
  footprint fell from 52.74 MB to 42.78 MB and the process-lifetime physical
  peak stayed fixed at 686.11 MB across all ten files;
- the previously rising resident count tracked reclaimable allocator pages,
  not live image buffers: resident bytes rose from 1.132 GB to 1.549 GB while
  reusable bytes rose from 1.069 GB to 1.467 GB. All-zone `vmmap` snapshots
  likewise identified reusable and empty allocator regions rather than dirty
  retained data;
- TIFF export now packs its three 16-bit RGB channels directly instead of
  allocating a padded RGBA buffer. The 40.19 MP intermediate is 80.37 MB
  smaller, the ten-file median packing interval fell from 29.73 ms to 22.88 ms
  (23.0%), and all ten TIFF byte counts and SHA-256 hashes remained identical.
- all four writers now split full-resolution channel packing across at most
  eight workers. JPEG and PNG also use compact RGB rather than padded RGBA
  inputs, removing 40.19 MB and 80.37 MB respectively at 40.19 MP. A same-RAW
  release A/B reduced the combined packing/finalization interval by 1.5% for
  TIFF, 2.4% for JPEG, 2.4% for PNG, and 30.0% for DNG while preserving each
  format's output byte count and SHA-256;
- the release-mode app-path benchmark now records first corrected paint,
  cached and uncached switching, rapid-selection drain, preview-cache bytes,
  and Mach physical footprint. On six local RAFs with three repetitions,
  p50/p95 were 50.71/63.72 ms for first paint, 14.57/83.98 ms for a cached
  switch, 126.32/126.32 ms for an uncached switch, and 81.55/133.77 ms for a
  six-file rapid-selection drain. The largest two-file preview cache was
  8.53 MB and the process ended at 28.79 MB physical footprint after a
  155.57 MB process-lifetime peak;
- the preview-cache depth run is complete on the same six-RAF corpus. Depth 2
  populated two sessions and 8.53 MB of logical preview data; depths 8 and 32
  both saturated at the six available files and 25.59 MB. Physical footprint
  after releasing each model returned to 27.82, 26.23, and 26.49 MB,
  respectively, so the run shows no sustained depth-by-depth growth. Absolute
  in-capacity footprint is reported but is not directly ordered because later
  samples reuse allocator pages from earlier samples;
- the release app path completed ten sequential TIFF jobs in 225.21 seconds
  over six unique local RAFs plus four duplicate queue additions. Per-job p50
  and nearest-rank p95 were 22.57 and 22.80 seconds. The observed physical
  footprint stayed between 71.03 and 74.14 MB, returned to 61.41 MB after model
  release, and all ten temporary outputs were removed. Cancellation requested
  250 ms into the first full-resolution decode stopped at the next safe boundary
  in 21.57 seconds, wrote no output, and returned to 59.62 MB after model release;

These numbers are diagnostic, not release claims. `ru_maxrss` and Mach
`resident_size` include reusable pages and are not live-memory gates; use
physical footprint plus allocator classification for that decision. The
current camera-scan decode contract is not comparable with the faster
RawPy-compatibility profile because the stage sets and demosaic algorithms
differ.

This closes the bounded performance cycle. The still-preview zoom/pan surface
is implemented in the current working tree; it still needs a direct
representative-image workflow check before the release gate is claimed closed.
Optimize export again only when a later measurement identifies a user-visible
or resource-safety problem. Preserve final-quality demosaic, output contracts,
and the one-full-resolution-RAW-at-a-time bound.

## Implemented Product Scope

| Area | Current behavior |
|---|---|
| Import | Drag/drop, file picker, Finder Open With, standard PNG/JPEG/BMP/TIFF decode, and LibRaw-backed camera RAW decode. |
| First paint | RAW embedded thumbnails and ImageIO standard-image thumbnails decode directly to at most 1000px off the main actor. A separate 256px proxy drives classification and median calibration before the first filtered render. |
| Processing | Color/B&W negative and slide startup classification, RawTherapee-compatible power-law inversion, a reference-derived Kodachrome-like adaptive look, an optional density pipeline, film-base measurement, flat field, capture-profile 3x3-plus-offset density correction before curve inversion, a neutral-preserving six-control dye-crossover matrix shared by basic/power-law/density color-negative paths, protected color and tone controls with center-weighted UI response and pipeline-calibrated tone references, shape-preserving overall/per-channel curves, color wheels, neutral-white handling for clipped near-zero holder pixels, automatic frame detection, a centered two-click horizontal/vertical straighten guide, an immediately visible post-straighten drag-box crop with full-canvas replacement and reset, an independent four-corner perspective warp with targeting reticles, a 100×100-pixel drag loupe, soft parallel-edge assistance, and a visible grid, live full-resolution output dimensions, frame, and aspect ratio. |
| Preview | First paint uses a bounded 16-bit 1000px display source plus a 256px analysis source. Embedded RAW pixels are fast previews, not authoritative RAW output. **Load RAW Preview** explicitly decodes the selected RAW through the app-facing camera-scan profile, builds an up-to-2400px display source, and recalibrates from those RAW pixels. A native scroll viewport supplies momentum pan, cursor-centered pinch zoom, Fit/step/100% commands, viewport-stable Original comparison, shared editing-overlay transforms, and an explicit source/dimension badge. The Core Image/Metal renderer uses latest-value-wins scheduling; CPU remains the reference and fallback. |
| Editing state | Per-file settings, named presets, a built-in Kodachrome-like Auto action, one-step removal of the last applied preset without resetting geometry, system-clipboard copy/paste, reset, edited markers, apply-to-all-open-files, and configurable 2/4/8/16/32-file lookahead. Lookahead caches preview sessions only and is bounded by count and 256 MiB. |
| Export | Named-sRGB TIFF, JPEG, and PNG plus output-referred linear-sRGB processed DNG; individual, ordered multi-selection, and lazy memory-bounded batch-all workflows; collision-safe names; partial-file cleanup; progress, per-file errors, queued cancellation, and duplicate-friendly append-selected jobs with per-addition export-setting snapshots during an active sequential run. |
| Dust | Native parity-tested candidate-mask detection and a non-destructive aligned overlay. Dust removal is not applied to preview or export. |
| Packaging | Self-contained app/ZIP/checksum assembly, embedded non-system libraries, bundle-relative load paths, licenses/notices/library manifest, icon/document registration, ad-hoc beta signing, gated Developer ID/notary support, local bundle validation, archive extraction/revalidation, and local packaged launch. |

See [Features](../features.md) for a user-facing description and
[`native/README.md`](../../native/README.md) for package-local implementation
and command details.

## Release Gates

### 1. Large-File Performance And Memory — Closed

The 2026-07-15 app-path batch and cancellation run closed this cycle. The
standing contract is:

- prompt bounded corrected feedback;
- no overlapping authoritative full-resolution decode buffers;
- one full-resolution RAW export at a time;
- no sustained physical-footprint growth through a representative batch;
- stable output and metadata across optimizations;
- documented p50/p95 latency and peak-live-memory baselines that future changes
  can detect regressions against.

### 2. Photographic Judgment And Editing Confidence

Implemented in the current working tree:

- native pan/pinch navigation plus Fit, zoom-in/out, and 100% commands;
- original/corrected comparison at the same viewport and magnification;
- a shared transform for image, dust, crop, straighten, and perspective layers;
- an explicit preview-source and displayed-dimensions badge.

Still required before calling the application high quality:

- complete a direct representative-image workflow check for focus, grain,
  dust, crop-edge, overlay-drag, comparison, and clipping-diagnostic behavior;
- add undo/redo with one history step per slider gesture and safe per-file
  boundaries;
- preserve the explicit bounded-preview versus full-resolution-export contract.

### 3. Roll And Batch Workflow

Exercise a real roll workflow: choose an anchor frame, establish a look, apply
it to selected or all open frames, correct exceptions, choose intended exports,
and complete the batch. Verify immediate visible application, preserved
per-frame geometry/base measurements, edited and queue state, and import-ordered
selection/export.

Sidebar reordering, ratings, or a larger queue become requirements only when
this workflow demonstrates a need.

### 4. Representative Packaged-App And Output Correctness — Beta Contract Closed

Exercise the actual packaged app, not only engine entry points:

- import representative standard images and RAWs;
- verify bounded corrected-preview orientation against reopened
  full-resolution exports;
- apply default power-law, density/flat-field, crop/perspective/frame, preset,
  batch, and relaunch workflows;
- export TIFF, JPEG, PNG, and DNG, then inspect dimensions, pixels, orientation,
  depth, metadata, and color interpretation;
- preserve the named-sRGB contract for TIFF/JPEG/PNG and the explicit
  output-referred linear-sRGB DNG metadata contract;
- test cancellation, collision handling, unwritable destinations, corrupt
  settings, relaunch, and partial-output cleanup;
- reproduce the originally reported PNG source/destination case.

The existing Fujifilm X-T5 RAF corpus is useful but insufficient as the entire
product claim. A small legally distributable committed CI corpus is preferable;
local-only files remain an explicitly supplemental gate.

### 5. Distribution Hardening

The release packager now provides a validated `unsigned-beta` path and a
fail-closed `public` path. The following remain for the notarized build:

- Developer ID sign;
- notarize and staple;
- pass Gatekeeper without a bypass;
- install and run on a supported clean Mac without Homebrew or the source tree;
- repeat the representative import/edit/export/relaunch smoke workflow.

## Known Limitations

- Telea dust inpainting and applying dust removal to preview/export are not
  implemented natively.
- Undo/redo is not implemented.
- Sidebar order remains import order. Manual reordering is unavailable and is
  not a release gate unless the roll workflow demonstrates a need.
- Lens-distortion correction and calibrated film-plane/sensor-plane
  non-alignment correction are not implemented. The current four-corner warp
  rectifies one planar film frame; it does not model curved or spatially varying
  distortion.
- RAW CI coverage depends partly on untracked local files; the committed corpus
  does not yet prove the complete packaged-app path.
- The available real RAW corpus is X-Trans and does not provide a committed
  real-file gate for the Bayer RCD path.
- Camera-scan ISO denoise/sharpen policy is a bounded native approximation, not
  an exact RawTherapee kernel port.
- TIFF, JPEG, and PNG use named sRGB profiles. Processed DNG uses
  output-referred linear-sRGB DNG metadata and may not open in applications
  that only support known-camera sensor DNGs; use TIFF for broad interchange.
- The density pipeline uses an authoritative CPU fallback rather than a fully
  product-integrated GPU path.
- Capture profiles can store a custom density correction, and the offline
  fitter produces a candidate plus fit/held-out/identity-baseline metrics while
  preventing frame leakage across the validation split. The repository does
  not contain the paired measured corpus needed to validate or ship a built-in
  capture/stock matrix. Reference-pair alignment and target-log-exposure
  extraction, fitted per-stock curves, residual LUTs, and halation compensation
  are not implemented. This calibration track is intentionally parked until the
  project owner explicitly asks to resume it.
- Processed-RGB DNG does not claim untouched sensor-RAW semantics.
- Standard images with alpha are rejected because four-channel processing has
  not been defined.
- The technical beta is ad-hoc signed and Apple Silicon-only. Developer ID
  notarization, no-bypass Gatekeeper assessment, and independent clean-machine
  validation have not been completed.

## Verification Summary

- 395 native tests across 28 files in the current working tree.
- Frozen Python-generated fixtures cover shared numerical behavior.
- Production CPU/GPU correction comparisons cover 2,725 channel comparisons
  with zero failures and a maximum difference of 2/255.
- A separate directed dye-crossover fixture verifies the new linear matrix
  against the production Metal renderer within the same 2/255 tolerance.
- Synthetic calibration tests recover a known density-space affine transform,
  enforce frame-level fit/validation separation, compare held-out RMSE against
  identity, and exercise capture-profile migration plus the app processing seam.
- Export tests cover format round trips, manager behavior, cancellation,
  collisions, partial cleanup, and app-level integration.
- Local packaging validates the assembled app and extracted ZIP copy, bundled
  license/notice/manifest resources, dependency closure, signature, and
  checksum-oriented archive contract.
- The GitHub workflow currently runs the Swift test suite and builds the app on
  macOS; it does not yet prove a notarized artifact or committed real RAW corpus.

## Development Rules

1. Protect data integrity, cancellation, and recoverable errors before adding
   features.
2. Test user-visible work through the real `AppModel`/packaged-app path where
   practical, not only isolated engine helpers.
3. Preserve exact shared legacy behavior only where compatibility is an actual
   product contract. New native behavior gets a deterministic Swift CPU
   authority and focused regression fixtures.
4. Profile before optimizing. Compare identical stage sets and quality
   contracts; never trade export fidelity for an unnamed speed mode.
5. Keep preview and export memory bounded. Do not retain a full import batch of
   decoded RAW buffers.
6. Treat implementation and documentation as one change. Update this page,
   Features, the roadmap, and specialized evidence pages only where their owned
   facts changed.
7. Do not expand the legacy Python product surface.

## Build And Test

The package requires macOS 14 or later and Homebrew LibRaw:

```sh
brew install libraw
swift test --package-path native/FilmScanEngine --no-parallel
swift build --package-path native/FilmScanEngine \
  --product FilmScanConverterMac
```

Create and validate a local self-contained artifact:

```sh
native/package-release.sh
```

Run the staged export benchmark:

```sh
swift build -c release --package-path native/FilmScanEngine \
  --product FilmScanExportBenchmark

native/FilmScanEngine/.build/release/FilmScanExportBenchmark \
  sample-raw /tmp/film-scan-export.json 3
```

Generated benchmark exports are hashed and removed after each repetition. See
the [benchmark notes](../performance/40mp-export.md) for options and the exact
measurement contract.

## Document Ownership

- [Roadmap](../improvements/MacOS-Native-Roadmap.md): ordered product work and
  explicit deferrals.
- [Features](../features.md): current user-visible capabilities and limitations.
- [Native release](native-release.md): signing, notarization, Gatekeeper, and
  clean-machine procedure.
- [40 MP benchmark](../performance/40mp-export.md): commands, measurements, and
  performance acceptance evidence.
- [Legacy Python](../legacy-python.md): maintenance boundary and retirement
  gates.
- [Film-processing research](../film-processing-research.md): scientific and
  algorithmic background, not delivery priority.
- [`native/README.md`](../../native/README.md): package structure, local build
  commands, and implementation notes.
