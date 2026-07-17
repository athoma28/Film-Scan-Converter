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
  output hashing and deletion;
- `FilmScanAdjustmentBenchmark`: release-mode preview benchmark with active
  dye crossover, protected color/tone, curves, and color wheels;
- `FilmScanPreviewComparator`: CPU/GPU visual and numerical comparison tool;
- `FilmScanReleaseValidator`: packaged-app contract validator;
- `FilmScanProcessingBenchmark`: focused processing benchmark;
- `FilmScanProfileCalibrator`: offline weighted density-matrix fitter with a
  frame-level held-out validation gate.

The package requires macOS 14 or later and Homebrew LibRaw. `CLibRawShim`
provides the narrow C/C++ boundary used by Swift. No LibRaw-owned buffer or
lifetime is exposed to the application.

## Build And Test

```sh
brew install libraw

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

Build a self-contained, locally ad-hoc-signed app and ZIP:

```sh
RELEASE_MODE=unsigned-beta RELEASE_LABEL=beta.1 native/package-release.sh
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

Run the staged 40 MP export benchmark:

```sh
swift build -c release --package-path native/FilmScanEngine \
  --product FilmScanExportBenchmark

native/FilmScanEngine/.build/release/FilmScanExportBenchmark \
  sample-raw /tmp/film-scan-export.json 3 --file=DSCF0669.RAF
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

This uses the local RAF corpus, emits a compact JSON latency/memory report, and
writes no exports. The report also samples preview-cache depths 2, 8, and 32,
including realized session count, logical cache bytes, fill latency, and
physical footprint before fill, at capacity, and after model release. A corpus
smaller than the configured depth is reported explicitly rather than treated as
a fully populated cache.

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

Run the RAW and preview tools:

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
decode against recorded hashes. The X-T5 regression trio additionally guards
camera-scan previews against leaked X-Trans mosaic pixels. Each corpus-dependent
test is explicitly disabled unless all files it needs are present.

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
- Use explicit image contracts: normal browsing starts with a 1000px display
  source and a 256px analysis source; the explicit **Load RAW Preview** action
  may replace the selected embedded RAW source with a demosaiced preview up to
  2400px; export owns an independent full-resolution decode.
- Keep lookahead preview-only, LRU, and bounded by both file count and bytes.
- Keep the still image, dust mask, and crop/straighten/perspective editors in
  one native viewport transform. Original comparison must preserve its pan and
  magnification, and selection changes must return to a predictable Fit state.
- Define 100% against the pixels in the current bounded preview, not the
  full-resolution export source. Keep the preview-source/dimensions badge
  visible so embedded RAW thumbnails are never presented as export evidence.
- Keep adaptive-look analysis bounded independently of imported image size;
  Kodachrome-like Auto currently analyzes at most a 1024-pixel long edge and
  stores a concrete five-point curve for deterministic preview/export parity.
- Treat `FilmDyeMixingParameters` as a neutral-preserving, linear-light film
  response operator, not a display white-balance replacement. Apply it after
  inversion and before semantic tone/protected color, curves, and grading in
  the basic, power-law, and density paths. Keep its CPU and Core Image kernels
  in parity, and keep the exact-neutral fast path bit-for-bit unchanged.
- User film-stock profiles persist exponent, dye-mixing, density-response, and
  display-rendering priors. Do not add named stock matrices until held-out
  measured data validates them.
- Keep a session-local rollback snapshot when applying a named preset or
  Kodachrome-like Auto so the look can be removed without resetting crop or
  orientation.
- Treat manual film-frame geometry as a persisted, validated clockwise
  four-corner quadrilateral. Its reticle/loupe editor may softly snap either
  incident edge parallel to its opposite edge, but must preserve an explicit
  free-drag path. Perspective state is independent from the later normalized
  canvas crop: changing or clearing one must not clear the other. Preview,
  dust-overlay alignment, density flat
  field, and export must use the same CPU perspective warp; this corrects one
  planar frame and is not a lens-distortion model.
- Resolve each two-point straighten guide against its nearest horizontal or
  vertical axis, then apply the persisted angle after quarter-turn rotation and
  flip. Apply the simple normalized canvas crop after that expanded rotation.
  Preview, full-resolution dimension prediction, flat field, dust overlay, and
  export must preserve this geometry order.
- Exclude manual crop from the Metal correction-only fast path until that path
  implements canvas cropping; committed crops must update the preview canvas
  immediately. While the Crop tool is active, preview the full post-straighten
  canvas so the next drag replaces the existing crop.
- Treat the Core Image/Metal renderer as the primary interactive development
  path on supported MacBook Pro hardware. Keep CPU rendering correct for
  deterministic tests, CI/headless runs, export/reference behavior, and fallback
  paths that are not GPU-integrated yet.
- Serialize fallback/detail decode work and full-resolution RAW export decode;
  check cancellation before entering synchronous LibRaw/ImageIO calls.
- Keep full-resolution RAW export one-file-at-a-time.
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
