# Test Suite

This directory contains legacy Python regression tests, compatibility-fixture
generators, and native benchmark helpers. The Python pipeline is no longer the
design authority for new features. Shared historical behavior is frozen here
for compatibility while new native behavior uses deterministic Swift CPU
contracts. See
[Native macOS Development](../docs/development/native-macos.md) for the current
development step and [Legacy Python Application](../docs/legacy-python.md) for
the retirement policy.

The default suite is deterministic, dependency-light, and designed to run quickly:

```sh
.venv/bin/python -m unittest discover -v
```

It verifies pixel equivalence against reference implementations for thresholding, dust detection, histogram equalization, histogram rendering, exposure, white balance, and contour overlays. It also verifies cache invalidation, multiprocessing serialization, processing-counter cleanup after exceptions, failed-write reporting and retry behavior, batch-export UI restoration, and export error-dialog formatting.

`generate_native_snapshots.py` also writes the standard-image decode fixtures
used by the Swift regression gate. They lock exact Python/OpenCV-equivalent
pixels for 8-bit color PNG, 8-bit grayscale PNG, BMP, and 16-bit TIFF inputs.
The JPEG fixture uses the documented native status-page tolerance because
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
with protected tone/color controls, curves, and color wheels:

```sh
swift run -c release --package-path native/FilmScanEngine \
  FilmScanAdjustmentBenchmark
```

Benchmarks report best-of-several timings and do not enforce hardware-specific timing thresholds.

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

The corpus manifest records film type, required rotation, representative scene type, and selected edit presets. Results include cold processing, warm cached processing, render timings, previews, and quality diagnostics.

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

The default native suite now exercises the actual AppKit scroll view through
draft/inspect/full-resolution size changes, panning, Fit, resize, and pinch
notifications. App-model comparison tests cover automatic crop, manual crop,
perspective, straightening, and their combination, including temporary editor
canvases and exact corrected-pixel restoration.

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
