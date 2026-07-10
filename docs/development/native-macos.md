# Native macOS Development Status

This is the authoritative statement of what the native application does, what
blocks a high-quality public release, and what is being worked on now. Use the
[roadmap](../improvements/MacOS-Native-Roadmap.md) for priority and scope, the
[feature inventory](../features.md) for user-visible behavior, and the
[40 MP benchmark](../performance/40mp-export.md) for detailed measurements.

**Last verified:** 2026-07-09 against the current working tree. The native test
suite contains 321 tests across 19 files. Some representative-RAW tests require
the untracked local `sample-raw/` corpus and are explicitly disabled when it is
absent.

## Release Position

The Swift/SwiftUI application is the primary product and the only destination
for new functionality. It is suitable for continued native development and
local validation, but it is not yet proven as a generally distributable
release.

The remaining release work is not “finish every historical phase.” It is to
prove the real application path, close essential editing-workflow gaps, measure
large-file memory and latency, and validate the final signed artifact on a
clean machine.

## Current Work

Finish the bounded 40 MP measurement cycle already in progress, then return to
release-candidate correctness and workflow work. Do not start another broad
performance rewrite from the existing one-file smoke result.

The current measurement evidence is:

- bounded RAW and standard-image provisional previews are implemented;
- selected and lookahead authoritative decodes are serialized and cancellable
  before entering the synchronous decoder;
- app-path signposts cover provisional loading, authoritative replacement, and
  export from queue wait through cleanup;
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

These numbers are diagnostic, not release claims. `ru_maxrss` and Mach
`resident_size` include reusable pages and are not live-memory gates; use
physical footprint plus allocator classification for that decision. The
current camera-scan decode contract is not comparable with the faster
RawPy-compatibility profile because the stage sets and demosaic algorithms
differ.

The next bounded measurements are:

1. p50/p95 provisional paint, authoritative replacement, cached/uncached
   switching, and rapid-selection drain;
2. an app-path ten-file sequential export with cancellation latency and
   post-run memory checks.

Optimize another stage only when those measurements identify a user-visible or
resource-safety problem. Preserve final-quality demosaic, output contracts, and
the one-full-resolution-RAW-at-a-time bound.

## Implemented Product Scope

| Area | Current behavior |
|---|---|
| Import | Drag/drop, file picker, Finder Open With, standard PNG/JPEG/BMP/TIFF decode, and LibRaw-backed camera RAW decode. |
| First paint | RAW embedded thumbnails and standard images use bounded provisional previews before authoritative background replacement. Orientation remains stable across the swap. |
| Processing | Color/B&W negative and slide startup classification, RawTherapee-compatible power-law inversion, an optional density pipeline, film-base measurement, flat field, protected color and tone controls, curves, color wheels, automatic frame detection, a two-click horizontal/vertical straighten guide, a post-straighten drag-box crop, a direct four-corner perspective crop grid, live full-resolution output dimensions, frame, and aspect ratio. |
| Preview | A bounded 16-bit Core Image/Metal still renderer uses latest-value-wins scheduling and is the primary interactive development target on supported MacBook Pro hardware. X-Trans RAW previews use one-pass full-mosaic interpolation followed by immediate 2× downsampling; this preserves the bounded cached shape without exposing LibRaw's incomplete half-size X-Trans output on bright frames. CPU rendering remains the deterministic reference, CI/headless path, and fallback for preview features that have not moved to GPU yet. |
| Editing state | Per-file settings, named presets, system-clipboard copy/paste, reset, edited markers, apply-to-all-open-files, and configurable 2/4/8/16/32-session lookahead cache. Transferred looks preserve target crop/orientation and measured film-base state. |
| Export | TIFF, JPEG, PNG, and processed-RGB DNG; individual and lazy memory-bounded batch-all workflows; collision-safe names; partial-file cleanup; progress, per-file errors, queued cancellation, and append-selected during an active sequential run. |
| Dust | Native parity-tested candidate-mask detection and a non-destructive aligned overlay. Dust removal is not applied to preview or export. |
| Packaging | Self-contained app/ZIP assembly, embedded non-system libraries, bundle-relative load paths, icon/document registration, hardened-runtime signing support, local bundle validation, archive extraction/revalidation, and local packaged launch. |

See [Features](../features.md) for a user-facing description and
[`native/README.md`](../../native/README.md) for package-local implementation
and command details.

## Release Gates

### 1. Representative End-to-End Correctness

Exercise the actual packaged app, not only engine entry points:

- import representative standard images and RAWs;
- wait for provisional-to-authoritative replacement and verify orientation;
- apply default power-law, density/flat-field, crop/perspective/frame, and saved
  settings workflows;
- export TIFF, JPEG, PNG, and DNG, then reopen and inspect dimensions, pixels,
  orientation, profile, and metadata as applicable;
- test cancellation, collision handling, unwritable destinations, corrupt
  settings, relaunch, and partial-output cleanup;
- reproduce the originally reported PNG source/destination case before closing
  that regression.

The existing Fujifilm X-T5 RAF corpus is useful but insufficient as the entire
product claim. Add or acquire held-out representative files only when their
license and repository footprint are explicit. A compact committed CI corpus
is preferable; local-only files must remain a clearly reported supplemental
gate.

### 2. Essential Editing Workflow

Before calling the application high quality, complete and validate:

- undo/redo for destructive editing-state changes;
- zoom and pan for judging focus, dust, crop, and corrections;
- native ordered multi-selection with lazy Export Selected;
- another real batch-editing usability pass covering file switching, applying a
  look, correcting exceptions, and exporting the intended subset.

The existing Original toggle is sufficient unless usability testing proves a
split comparison materially better. Sidebar reordering is useful but does not
block the first release unless scan order is shown to be unreliable in real
workflows.

### 3. Large-File Performance And Memory

Close the current measurement cycle. The release gate is not an arbitrary
multiple of Python performance. It is:

- prompt provisional feedback;
- no overlapping authoritative full-resolution decode buffers;
- one full-resolution RAW export at a time;
- no sustained physical-footprint growth through a representative batch (the
  engine-level ten-file gate now passes; the app-path gate remains);
- stable output and metadata across optimizations;
- documented p50/p95 latency and peak-live-memory baselines that future changes
  can detect regressions against.

### 4. Distribution

Use the [native release runbook](native-release.md) with the final candidate:

- Developer ID sign;
- notarize and staple;
- pass Gatekeeper without a bypass;
- install and run on a supported clean Mac without Homebrew or the source tree;
- repeat the representative import/edit/export/relaunch smoke workflow.

## Known Limitations

- Telea dust inpainting and applying dust removal to preview/export are not
  implemented natively.
- Undo/redo, zoom/pan, ordered multi-selection, Export Selected, and sidebar
  reordering remain incomplete.
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
- The density pipeline uses an authoritative CPU fallback rather than a fully
  product-integrated GPU path.
- Processed-RGB DNG does not claim untouched sensor-RAW semantics.
- Standard images with alpha are rejected because four-channel processing has
  not been defined.
- Developer ID notarization, Gatekeeper, and clean-machine validation have not
  been completed.

## Verification Summary

- 331 native tests across 19 files in the current working tree.
- Frozen Python-generated fixtures cover shared numerical behavior.
- Production CPU/GPU correction comparisons cover 2,725 channel comparisons
  with zero failures and a maximum difference of 2/255.
- Export tests cover format round trips, manager behavior, cancellation,
  collisions, partial cleanup, and app-level integration.
- Local packaging validates the assembled app and the extracted ZIP copy.
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
