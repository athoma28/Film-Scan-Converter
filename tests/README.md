# Test Suite

This directory contains the Python reference and regression tests. The Python
pipeline remains the source of truth while the native engine is ported. See
[Native macOS Development](../docs/development/native-macos.md) for the current
porting step and the combined Python/Swift test workflow.

The default suite is deterministic, dependency-light, and designed to run quickly:

```sh
python3 -m unittest discover -v
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
present. The RAF files remain outside version control.

Performance benchmarks are opt-in so normal test runs remain stable:

```sh
RUN_PERFORMANCE_TESTS=1 python3 -m unittest tests.test_performance -v
```

Benchmarks report best-of-several timings and do not enforce hardware-specific timing thresholds.

The representative RAF corpus benchmark uses decoded 16-bit BGR arrays:

```sh
python3 tests/generate_raw_decode_reference.py

python3 tests/decode_sample_raw.py \
  --raw-dir sample-raw \
  --output-dir /tmp/film_scan_corpus

python3 tests/benchmark_sample_raw.py \
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

python3 tests/compare_raw_decode_benchmarks.py \
  --rawpy /tmp/film_scan_corpus/decode_results.json \
  --native /tmp/film_scan_native_decode.json \
  --output /tmp/film_scan_decode_comparison.json
```

See [Native RAW Decode And Quality Benchmark](../docs/development/native-raw-benchmark.md)
for the verified five-file results.
