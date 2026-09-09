# Test Suite

This directory contains legacy Python regression tests, compatibility-fixture
generators, and native benchmark helpers. The Python pipeline is no longer the
design authority for new features. Shared historical behavior is frozen here
for compatibility while new native behavior uses deterministic Swift CPU
contracts. See
[Native macOS Development](../docs/development/native-macos.md) for current
verification and [Legacy Python Application](../docs/legacy-python.md) for
the retirement policy.

## Native Regression

From the repository root, run with normal macOS graphics access:

```sh
swift test --package-path native/FilmScanEngine --no-parallel
```

Use `-c release` for performance comparisons. Default native runs skip opt-in
benchmarks and the representative roll workflow. RAW-dependent tests explicitly
skip when their local inputs are unavailable. Latest test counts and platform
coverage are recorded in [development status](../docs/development/native-macos.md).

## Legacy Python Regression

The Python regression suite is deterministic and dependency-light:

```sh
.venv/bin/python -m unittest discover -s tests -p 'test_*.py'
```

It verifies pixel equivalence against reference implementations for thresholding, dust detection, histogram equalization, histogram rendering, exposure, white balance, and contour overlays. It also verifies cache invalidation, multiprocessing serialization, processing-counter cleanup after exceptions, failed-write reporting and retry behavior, batch-export UI restoration, and export error-dialog formatting.

`generate_native_snapshots.py` also writes the standard-image decode fixtures
used by the Swift regression gate. They lock exact Python/OpenCV-equivalent
pixels for 8-bit color PNG, 8-bit grayscale PNG, BMP, and 16-bit TIFF inputs.
The JPEG fixture permits maximum UInt16 difference 2,560 and mean difference
512 because
ImageIO and OpenCV use different lossy JPEG decoders.

`generate_raw_decode_reference.py` writes a compact manifest of dimensions,
color descriptions, and SHA-256 pixel hashes for the five representative
half-size RAF decodes plus one full-resolution decode. The Swift LibRaw tests
consume that manifest and require exact RawPy equality when `sample-raw/` is
present. A separate camera-scan fixture,
`native/FilmScanEngine/Tests/FilmScanEngineTests/Fixtures/camera_scan_decode_reference.json`,
pins the full-resolution `rawTherapeeCameraScan` decode of
`fuji400-fresh/DSCF2833.RAF` (stage digests plus Swift pixels). When the
untracked RAF corpus is absent, default corpus-specific Swift tests are reported as
disabled with an explicit reason rather than silently passing.
The RAF files remain outside version control. Discovery is recursive so the
corpus can be organized by film stock; manifests and benchmark reports store
root-relative paths, and ambiguous historical basenames are rejected.

Performance benchmarks are opt-in so normal test runs remain stable:

```sh
RUN_PERFORMANCE_TESTS=1 .venv/bin/python -m unittest tests.test_performance -v
```

The deterministic Metal adjustment benchmark runs a fixed 1080×720 workload
with dye crossover, protected tone/color controls, curves, and color wheels:

```sh
swift run -c release --package-path native/FilmScanEngine \
  FilmScanAdjustmentBenchmark
```

The Python timing tests report best-of-several samples. Native benchmarks
report their own raw samples and median/p95 summaries; the opt-in renderer
burst gate also checks a 33 ms p95 target. Read each harness before comparing
results across workloads or hardware.

[Preview analysis](../docs/performance/preview-analysis.md) documents CPU
diagnostics and Darkroom benchmarks, including exact analysis/output hashes.
[40 MP export](../docs/performance/40mp-export.md) documents decode, packing,
writer, queue, cancellation, and physical-footprint measurements.

The representative RAF corpus benchmark uses decoded 16-bit BGR arrays and
automatically selects the first root-relative frame in each top-level stock
folder. XMP grayscale metadata selects the B&W processing path.

```sh
.venv/bin/python tests/generate_raw_decode_reference.py \
  --file misc/DSCF2819.RAF \
  --file fuji400-fresh/DSCF2833.RAF \
  --file fuji200-expired/DSCF3160.RAF \
  --file shanghaigp3/DSCF3200.RAF \
  --file cinestill800t/DSCF3247.RAF \
  --full-resolution-file fuji400-fresh/DSCF2833.RAF

.venv/bin/python tests/decode_sample_raw.py \
  --raw-dir sample-raw \
  --output-dir /tmp/film_scan_corpus

.venv/bin/python tests/benchmark_sample_raw.py \
  --decoded-dir /tmp/film_scan_corpus \
  --output-dir /tmp/film_scan_benchmark
```

The corpus manifest records film type, rotation, scene metadata, and selected
edit presets. Results include uncached and warm processing, render timings,
previews, and quality diagnostics; these do not imply a physically cold disk.

Compare native and RawPy decode performance and decoded-image quality:

```sh
swift build -c release \
  --package-path native/FilmScanEngine \
  --product FilmScanRawBenchmark

native/FilmScanEngine/.build/release/FilmScanRawBenchmark \
  sample-raw /tmp/film_scan_native_decode.json 3

.venv/bin/python tests/compare_raw_decode_benchmarks.py \
  --rawpy /tmp/film_scan_corpus/decode_results.json \
  --native /tmp/film_scan_native_decode.json \
  --output /tmp/film_scan_decode_comparison.json
```

See [Native RAW Compatibility Decode And Quality Benchmark](../docs/development/native-raw-benchmark.md)
for the eight-file compatibility-profile snapshot and its distinction from the
current app export profile.

## Native Viewport And Roll Workflow

The default native suite exercises the actual AppKit scroll view through
draft/inspect/full-resolution size changes, panning, Fit, resize, and pinch
notifications. App-model comparison tests cover automatic crop, manual crop,
perspective, straightening, and their combination, including temporary editor
canvases and exact corrected-pixel restoration.
Source-editor regressions also exercise perspective edits, Reset, exposure,
and presets through Undo/Redo with Original comparison initially on and off.
They require the oriented original pixels to remain visible until the editor
closes, persisted settings to restore, and later history to reveal corrections
normally. GPU source previews use the existing 2/255 channel tolerance.

`CropAspectRatioTests` covers centered fitting, all eight handle anchors,
bounds, minimum sizes, landscape/portrait canvases, Fit/100%/zoomed drawing,
legacy settings, and preservation of destination geometry during look transfer.
`CropAspectRatioAppTests` exercises ratio changes and coalesced resize history,
uncropped editing, Free mode, per-file isolation, relaunch, and TIFF output
against CPU pixels after rotation, perspective, and straightening. Run these
with `--filter CropAspectRatio` and normal macOS graphics access.

Run the supplemental three-frame RAW workflow in a release build:

```sh
RUN_REPRESENTATIVE_ROLL_TESTS=1 \
CLANG_MODULE_CACHE_PATH=/tmp/film-scan-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/film-scan-swiftpm-cache \
swift test --disable-sandbox -c release \
  --package-path native/FilmScanEngine --no-parallel \
  --filter RepresentativeRollWorkflowTests
```

This requires `fuji400-fresh/DSCF2833.RAF`, `DSCF2851.RAF`, and `DSCF2856.RAF`
in the untracked `sample-raw/` corpus; explicitly enabling this workflow with
missing files fails the test. It applies an anchor look to selected
frames, checks an untouched frame and a reversible per-frame exception,
compares the full-resolution preview, exports in import order, changes settings
and re-exports through the retained decode, and restores persisted edits in a
new app model. Settings and TIFFs use a unique temporary directory; source
hashes must remain unchanged and all outputs are removed. This automated check
does not replace a hands-on assessment of focus, grain, gesture feel, or overlay
dragging in the packaged app.

## Independent-Viewer Output Contract

Contact-sheet tests exercise the actual app export path with selected/all
scans, edits changed after the export snapshot, active comparison/crop tools,
case-insensitive filename collisions, cancellation, failure/retry, and enabled
stack consolidation. PDFKit checks filenames and pagination at 12/13/25 scans;
Core Graphics checks corrected tile pixels. A local three-RAF case verifies
bounded preview export without populating the full-resolution export cache.

To retain the three-RAW PDF and a pagination fixture for file-based visual review:

```sh
CONTACT_SHEET_QA_OUTPUT=/tmp/fsc-contact-sheet-qa/contact-sheet.pdf \
CLANG_MODULE_CACHE_PATH=/tmp/film-scan-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/film-scan-swiftpm-cache \
swift test --disable-sandbox -c release --package-path native/FilmScanEngine \
  --no-parallel --filter ContactSheetExportTests
```

The RAW case requires `fuji400-fresh/DSCF2833.RAF`,
`cinestill800t/DSCF3247.RAF`, and `shanghaigp3/DSCF3200.RAF`; it explicitly
skips when those local files are missing. Without the output environment
variable, all generated PDFs are removed after testing.

App-path TIFF, JPEG, and PNG exports are reopened by ImageIO and `/usr/bin/sips`
as a second macOS reader. The check requires named sRGB, baked orientation
(tag 1), honest bit depth (16/8/16), and dimensions that match the on-canvas
geometry plus export frame. Processed DNG is inspected from TIFF/DNG tags,
including UniqueCameraModel `Film Scan Converter Processed RGB` and
output-referred ColorimetricInterpretation; it is not required to open as a
camera RAW in Preview. The opt-in three-frame RAW roll applies the same
named-sRGB TIFF inspection to its exported files.

```sh
swift test --disable-sandbox --package-path native/FilmScanEngine --no-parallel \
  --filter IndependentViewerOutputTests
```
