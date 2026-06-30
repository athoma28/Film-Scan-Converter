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
present. When the untracked RAF corpus is absent, corpus-specific Swift tests
are reported as disabled with an explicit reason rather than silently passing.
The RAF files remain outside version control.

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

The representative RAF corpus benchmark uses decoded 16-bit BGR arrays:

```sh
.venv/bin/python tests/generate_raw_decode_reference.py

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

See [Native RAW Decode And Quality Benchmark](../docs/development/native-raw-benchmark.md)
for the verified five-file results.
