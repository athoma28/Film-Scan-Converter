# Native macOS Development Status

This is the authoritative statement of what the native application does, what
blocks a high-quality public release, and what is being worked on now. Use the
[roadmap](../improvements/MacOS-Native-Roadmap.md) for priority and scope, the
[feature inventory](../features.md) for user-visible behavior, and the
[40 MP benchmark](../performance/40mp-export.md) for committed measurements.
The audited
[full-resolution performance guide](../../PERFORMANCE-OPPORTUNITIES-2026-07-27.md)
records the active optimization evidence and implementation sequence.

**Last verified:** 2026-08-12 against the current working tree. The native test
suite contains 443 tests across 32 files. Some representative-RAW tests require
the untracked local `sample-raw/` corpus and are explicitly disabled when it is
absent.

## Release Position

The Swift/SwiftUI application is the primary product and the only destination
for new functionality. It is ready for an explicitly labeled, ad-hoc-signed,
Apple Silicon technical beta on macOS 14 or later. It is not yet an
Apple-notarized general release.

The technical beta boundary is intentionally smaller than the high-quality
first-release standard below. A deeper representative roll pass, Developer ID
notarization, and independent-Mac validation remain important, but are
disclosed beta limitations rather than reasons to withhold useful open-source
software.

Stock-specific look learning and calibration are not part of the active plan.
The existing generic controls, profile seams, fitter, and research notes remain
available, but no further corpus preparation, named-stock fitting, or ML work
should begin until the project owner explicitly reactivates that track.

## Current Work

The bounded 40 MP measurement cycle and beta packaging/output correctness work
are complete. The still-preview viewport has native pan/pinch navigation,
Fit/step/100% commands, shared image and editing-overlay transforms,
viewport-stable comparison, and explicit preview-source status. Per-file
undo/redo now covers processing, geometry, framing, reset, paste, and
profile/preset application, with one history step per continuous editing
gesture and transient history restored independently for each selected scan.
**Apply Look to Selected** now transfers the active frame's look to the
import-ordered multi-selection while preserving each target's geometry and
measured film base.

A 2026-07-27 audit has reopened one bounded performance slice before broader
roll-workflow expansion. Camera-scan stage hashes and the repeated determinism
mode landed on 2026-07-28 with a passing stock-build baseline, and the
full-resolution X-Trans camera-scan byte-identity fixture followed the same
day. The 2026-07-30 forced-OpenMP sweep then isolated tiled X-Trans demosaic as
the first changed and nondeterministic boundary while proving threaded Fuji
unpack stayed byte-identical. The adjusted correction benchmark scenarios and
full-resolution byte-identity fixture followed on 2026-08-03, locating the
adjusted-path memory peak. The adjusted correction passes were then made
in-place and parallel on 2026-08-12, halving the measured process-lifetime peak
while preserving the committed scenario digests byte-for-byte. The X-Trans
repair completed the bounded performance slice later on 2026-08-12: the shim
keeps LibRaw's serial tile/interpolation order and parallelizes only independent
back-half rows, reproducing all approved digests across five eight-worker runs.
Next complete the representative-image viewport check, then resume the real
roll workflow. Do not begin a broad port, writer replacement,
batch-prefetch design, or stock-look calibration without satisfying the
roadmap gates.

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
- the benchmark's `--determinism` mode repeats full-resolution camera-scan
  decodes with opt-in SHA-256 capture at eight pipeline boundaries (unpacked
  mosaic, demosaiced image, processed image, post-ISO image, Swift image,
  corrected image, writer-input pixels, output file) and reports per-boundary
  agreement in pipeline order. On 2026-07-28 the stock Homebrew LibRaw 0.21.4
  build agreed at every boundary across five repetitions of
  `fuji400-fresh/DSCF2833.RAF`, with a fixed 683.9 MB process-lifetime peak
  physical footprint and every output removed; the stable digests are recorded
  in the 40 MP notes and anchor the byte-identity fixture committed the same
  day;
- one 40.19 MP RAF-to-TIFF smoke run took 27.51 seconds and reached a 1.20 GB
  process-lifetime peak RSS;
- 19.71 of 21.68 decode seconds were spent in final-quality three-pass X-Trans
  demosaic;
- an isolated audit build of LibRaw 0.21.4 with forced OpenMP reduced a separate
  Fuji processed-DNG workload from 14.74 to 2.10 seconds, with demosaic falling
  from 13.18 to 1.38 seconds and unpack from 0.89 to 0.11–0.13 seconds. A
  one-thread forced build matched the stock output, but two 14-thread runs
  differed from the reference and from each other. The 2026-07-30 pinned
  follow-up swept 1/2/4/8/10/14 threads with five repetitions each: every
  unpacked mosaic matched stock; 2 and 4 threads repeated but changed at
  `demosaicedImage`; 8, 10, and 14 first became non-repeatable at that same
  boundary. The 14-thread low-power run used 2.51–2.74 seconds for demosaic
  versus 16.53–17.18 at one thread and held a 701.6 MB process-lifetime peak
  physical footprint. This is a located opportunity and failed pixel candidate,
  not a production result;
- the production repair does not enable LibRaw's overlapping OpenMP tile loop.
  It preserves tile and order-sensitive interpolation order, while CIELab,
  derivative, homogeneity, and final-write rows use at most eight workers. Five
  release repetitions of `DSCF2833.RAF` reproduced all eight committed
  boundaries and output bytes exactly. Warm demosaic measured 3.38–3.54 seconds
  versus the stock 12.72–12.77-second baseline, with a 694.0 MB peak physical
  footprint;
- the closing 18-output format matrix removed every output; `DSCF2833.RAF`
  format medians were 6.33 seconds TIFF, 5.12 JPEG, 8.41 PNG, and 5.14 DNG.
  A separate ten-file TIFF sequence removed all ten outputs, held post-release
  footprint within 45.5–53.6 MB, and held the process peak to 686.8 MB. The
  ten-job app path completed in 50.07 seconds without errors or retained output;
  cancellation reached the post-decode boundary in 4.74 seconds and wrote no
  output;
- the 2026-08-03 correction-scenario matrix measured the neutral fused path and
  tone, protected-color, dye-mixing, and combined adjusted paths over three
  40.19 MP release repetitions. Corrected/output hashes repeated exactly and
  all 15 TIFFs were removed. Corrected-stage medians were 0.105, 2.182, 2.266,
  1.885, and 2.749 seconds respectively; post-scenario physical footprint stayed
  within 47.3–54.2 MB, while the adjusted paths raised process-lifetime peak
  physical footprint to 1.984 GB. The serial full-frame `Double` seam was then
  reduced in place on 2026-08-12: tone, protected-color, and dye-mixing now run
  in-place and in parallel, dropping the adjusted-scenario process-lifetime peak
  to 1.017 GB while the committed scenario digests still reproduce byte-for-byte;
- the in-place parallel adjusted seam cut the measured correction-scenario
  medians (tone 2.182→0.954 s, protected color 2.266→0.993 s, dye mixing
  1.885→0.944 s, combined 2.749→1.269 s) on a run whose decode had slowed to
  21.5–22.5 s from the 14.3–14.9 s baseline, so those latencies are directional
  while the peak-footprint and byte-identity results are machine-independent;
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

The original baseline cycle remains closed; the audit created a narrower
evidence-driven follow-up because it demonstrated a potentially user-visible
decode improvement and exposed a determinism failure. The still-preview
zoom/pan surface is implemented in the current working tree and still needs a
direct representative-image workflow check. Preserve final-quality demosaic,
output contracts, and the one-full-resolution-RAW-at-a-time bound throughout
the follow-up.

## Implemented Product Scope

| Area | Current behavior |
|---|---|
| Import | Drag/drop, file picker, Finder Open With, standard PNG/JPEG/BMP/TIFF decode, and LibRaw-backed camera RAW decode. |
| First paint | RAW embedded thumbnails and ImageIO standard-image thumbnails decode directly to at most 1000px off the main actor. A separate 256px proxy drives classification and median calibration before the first filtered render. |
| Processing | Color/B&W negative and slide startup classification, RawTherapee-compatible power-law inversion, a reference-derived Kodachrome-like adaptive look, an optional density pipeline, film-base measurement, flat field, capture-profile 3x3-plus-offset density correction before curve inversion, a neutral-preserving six-control dye-crossover matrix shared by basic/power-law/density color-negative paths, protected color and tone controls with center-weighted UI response and pipeline-calibrated tone references, shape-preserving overall/per-channel curves, color wheels, neutral-white handling for clipped near-zero holder pixels, automatic frame detection, a centered two-click horizontal/vertical straighten guide, an immediately visible post-straighten drag-box crop with full-canvas replacement and reset, an independent four-corner perspective warp with targeting reticles, a 100×100-pixel drag loupe, soft parallel-edge assistance, and a visible grid, live full-resolution output dimensions, frame, and aspect ratio. |
| Preview | First paint uses a bounded 16-bit 1000px display source plus a 256px analysis source. Embedded RAW pixels are fast previews, not authoritative RAW output. **Load RAW Preview** explicitly decodes the selected RAW through the app-facing camera-scan profile, builds an up-to-2400px display source, and recalibrates from those RAW pixels. A native scroll viewport supplies momentum pan, cursor-centered pinch zoom, Fit/step/100% commands, viewport-stable Original comparison, shared editing-overlay transforms, and an explicit source/dimension badge. The Core Image/Metal renderer uses latest-value-wins scheduling; CPU remains the reference and fallback. |
| Editing state | Per-file settings plus session-local per-file Undo/Redo for processing, geometry, output framing, reset, paste, and profile/preset application. Continuous slider, curve, color-wheel, and perspective gestures coalesce to one step; the restored current state persists while history starts empty after relaunch. Named presets, a built-in Kodachrome-like Auto action, one-step preset removal, system-clipboard copy/paste, edited markers, apply-to-selected/all with per-frame geometry and measured-base preservation, and configurable 2/4/8/16/32-file lookahead are also implemented. Lookahead caches preview sessions only and is bounded by count and 256 MiB. |
| Export | Named-sRGB TIFF, JPEG, and PNG plus output-referred linear-sRGB processed DNG; individual, ordered multi-selection, and lazy memory-bounded batch-all workflows; collision-safe names; partial-file cleanup; progress, per-file errors, queued cancellation, and duplicate-friendly append-selected jobs with per-addition export-setting snapshots during an active sequential run. |
| Dust | Native parity-tested candidate-mask detection and a non-destructive aligned overlay. Dust removal is not applied to preview or export. |
| Packaging | Self-contained app/ZIP/checksum assembly, embedded non-system libraries, bundle-relative load paths, licenses/notices/library manifest, icon/document registration, ad-hoc beta signing, gated Developer ID/notary support, local bundle validation, archive extraction/revalidation, and local packaged launch. |

See [Features](../features.md) for a user-facing description and
[`native/README.md`](../../native/README.md) for package-local implementation
and command details.

## Release Gates

### 1. Large-File Performance And Memory — Follow-Up Closed 2026-08-12

The 2026-07-15 app-path batch and cancellation run closed the baseline cycle.
The 2026-07-27 audit added a bounded follow-up with this order:

1. benchmark instrumentation and the camera-scan byte-identity fixture (both
   landed 2026-07-28);
2. isolation and repair of the existing LibRaw threaded-path divergence
   (isolated 2026-07-30; deterministic row-parallel repair landed 2026-08-12);
3. measured reduction of adjusted-correction allocations and serial passes
   (landed 2026-08-12: in-place parallel tone/protected-color/dye-mixing with
   byte-identical scenario digests and a 1.984 GB → 1.017 GB peak);
4. only then, re-evaluation of compression writers, batch overlap, Bayer RCD,
   or micro-optimizations.

The standing contract is:

- prompt bounded corrected feedback;
- no overlapping authoritative full-resolution decode buffers;
- one full-resolution RAW export at a time;
- no sustained physical-footprint growth through a representative batch;
- stable output and metadata across optimizations;
- documented p50/p95 latency and peak-live-memory baselines that future changes
  can detect regressions against;
- final-quality camera-scan threading must repeat deterministically at least
  five times per fixture before its speed is considered;
- any custom LibRaw dependency must pass packaging and clean-machine gates.

### 2. Photographic Judgment And Editing Confidence

Implemented in the current working tree:

- native pan/pinch navigation plus Fit, zoom-in/out, and 100% commands;
- original/corrected comparison at the same viewport and magnification;
- a shared transform for image, dust, crop, straighten, and perspective layers;
- an explicit preview-source and displayed-dimensions badge.
- native Undo/Redo with exact parameter snapshots, one history step per
  continuous gesture, and safe per-file boundaries.

Still required before calling the application high quality:

- complete a direct representative-image workflow check for focus, grain,
  dust, crop-edge, overlay-drag, comparison, and clipping-diagnostic behavior;
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
- Sidebar order remains import order. Manual reordering is unavailable and is
  not a release gate unless the roll workflow demonstrates a need.
- Lens-distortion correction and calibrated film-plane/sensor-plane
  non-alignment correction are not implemented. The current four-corner warp
  rectifies one planar film frame; it does not model curved or spatially varying
  distortion.
- RAW CI coverage depends partly on untracked local files; the committed corpus
  does not yet prove the complete packaged-app path.
- The camera-scan full-resolution byte-identity fixture
  (`camera_scan_decode_reference.json` plus `CameraScanByteIdentityTests`)
  pins the image shape, mosaic metadata, and all five decode-stage digests
  from the 2026-07-28 stock-build baseline. It is a same-machine, same-build
  contract, not a cross-platform identity proof; refresh it only from a
  documented repeated determinism run. The separate exact full-output
  reference still belongs to the faster `rawPyCompatibility` profile and must
  not be presented as camera-scan proof.
- LibRaw's forced-OpenMP path first changes pixels at tiled X-Trans demosaic,
  as isolated by the 2026-07-30 worker-count sweep. It remains disabled. The
  production shim instead parallelizes only independent rows within each
  serially ordered tile and reproduces the approved pixels. This retains an
  adapted LibRaw 0.21.4 algorithm body that must be reviewed when LibRaw is
  upgraded.
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

- 456 native tests across 32 files in the current working tree.
- The camera-scan byte-identity fixture
  (`camera_scan_decode_reference.json` plus `CameraScanByteIdentityTests`)
  pins the full-resolution X-Trans decode of `fuji400-fresh/DSCF2833.RAF` to
  the 2026-07-28 determinism baseline: image shape, color description, mosaic
  metadata, all five decode-stage digests, and the Swift pixel hash must
  reproduce exactly.
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
- The isolated LibRaw audit established that existing upstream threading can
  accelerate the tested Fuji workload. The completed six-count follow-up
  isolated tiled X-Trans demosaic as the first changed boundary, proved
  threaded unpack remains exact for the fixture, and confirmed that enabling
  the candidate wholesale fails determinism and exactness. The completed
  production repair preserves the serial dependency chain, parallelizes only
  independent back-half rows, and passes the original exact-output fixture.
  The detailed experiment is in the full-resolution performance guide.
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
- [Full-resolution performance guide](../../PERFORMANCE-OPPORTUNITIES-2026-07-27.md):
  audited optimization priorities, rejected shortcuts, and developer handoff.
- [Legacy Python](../legacy-python.md): maintenance boundary and retirement
  gates.
- [Film-processing research](../film-processing-research.md): scientific and
  algorithmic background, not delivery priority.
- [`native/README.md`](../../native/README.md): package structure, local build
  commands, and implementation notes.
