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
- `FilmScanAdjustmentBenchmark`: release-mode preview adjustment benchmark;
- `FilmScanPreviewComparator`: CPU/GPU visual and numerical comparison tool;
- `FilmScanReleaseValidator`: packaged-app contract validator;
- `FilmScanProcessingBenchmark`: focused processing benchmark.

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

## Packaged-App Validation

Build a self-contained, locally ad-hoc-signed app and ZIP:

```sh
native/package-release.sh
open "dist/Film Scan Converter.app"
```

The packager embeds non-system dynamic libraries, rewrites bundle load paths,
signs in dependency order, validates the app, creates the ZIP, extracts it, and
validates the archived copy. Set `SIGNING_IDENTITY` to an exact Developer ID
Application identity only for a distribution candidate. Follow the
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
writes no exports.

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
- Use explicit image contracts: a 1000px display source, a 256px analysis
  source, optional selected-file RAW detail for validated features, and an
  independent full-resolution export decode.
- Keep lookahead preview-only, LRU, and bounded by both file count and bytes.
- Keep adaptive-look analysis bounded independently of imported image size;
  Kodachrome-like Auto currently analyzes at most a 1024-pixel long edge and
  stores a concrete five-point curve for deterministic preview/export parity.
- Keep a session-local rollback snapshot when applying a named preset or
  Kodachrome-like Auto so the look can be removed without resetting crop or
  orientation.
- Treat manual film-frame geometry as a persisted, validated clockwise
  four-corner quadrilateral. Preview, dust-overlay alignment, density flat
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
- Serialize authoritative large-image decode work and check cancellation before
  entering synchronous LibRaw/ImageIO calls.
- Keep full-resolution RAW export one-file-at-a-time.
- Give export priority over speculative lookahead work and check cancellation
  between decode, correction, geometry, and write stages.
- Preserve atomic staging, collision-safe naming, and cleanup on export failure.
- Compare performance only across identical profiles, stage sets, hardware, and
  quality contracts.
- Keep product claims in `docs/features.md`, current evidence in
  `docs/development/native-macos.md`, and priority in the roadmap.

## Live Camera Scope

Live preview works only when macOS exposes the camera or capture adapter as an
AVFoundation video device. It is a fast preview path; final stills use the
16-bit import and export pipeline. Vendor-specific tethering is not active
roadmap work.
