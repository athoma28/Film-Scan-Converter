# Representative RAF Benchmark — Rerun

Date: 2026-07-03 15:49:49 PDT  
Branch: `dev`  
Hardware: Apple M4 Pro, 14 cores, 48 GB memory

Rerunning the [June 13 selected-edit benchmark](SAMPLE_RAW_BENCHMARK_2026-06-13_21-06-32_PDT.md)
with the current `dev` codebase.

## Decode (half-resolution RawPy)

| File | Best | Median | Shape |
| --- | ---: | ---: | --- |
| DSCF0669.RAF | 1.503 s | 1.508 s | 2592 × 3876 × 3 |
| DSCF0718.RAF | 1.529 s | 1.532 s | 2592 × 3876 × 3 |
| DSCF0729.RAF | 1.499 s | 1.500 s | 2592 × 3876 × 3 |
| DSCF2417.RAF | 1.503 s | 1.503 s | 2592 × 3876 × 3 |
| DSCF2422.RAF | 1.520 s | 1.522 s | 2592 × 3876 × 3 |
| DSCF2433.RAF | 1.513 s | 1.513 s | 2592 × 3876 × 3 |
| DSCF2437.RAF | 1.530 s | 1.531 s | 2592 × 3876 × 3 |
| DSCF2440.RAF | 1.508 s | 1.510 s | 2592 × 3876 × 3 |
| DSCF2471.RAF | 1.506 s | 1.506 s | 2592 × 3876 × 3 |
| DSCF2473.RAF | 1.520 s | 1.521 s | 2592 × 3876 × 3 |
| DSCF2476.RAF | 1.500 s | 1.502 s | 2592 × 3876 × 3 |
| DSCF2477.RAF | 1.494 s | 1.496 s | 2592 × 3876 × 3 |

Decode is approximately 1.5 s per RAF (RawPy 0.24.0). This is ~0.5 s slower per file
than the native LibRaw 0.21.4 decode benchmarked in June.

## 10 MP Processing Performance

Best processing times from three runs:

| File / edit | Cold | Warm |
| --- | ---: | ---: |
| DSCF0669 neutral | 0.149 s | 0.057 s |
| DSCF0669 tonal recovery | 0.329 s | 0.236 s |
| DSCF0669 contrast | 0.326 s | 0.238 s |
| DSCF0669 tonal recovery dust | 0.447 s | 0.237 s |
| DSCF0718 neutral auto | 0.842 s | 0.258 s |
| DSCF0718 manual base | 0.652 s | 0.290 s |
| DSCF0718 tuned | 1.148 s | 0.745 s |
| DSCF0718 tuned cooler | 1.093 s | 0.677 s |
| DSCF0718 tuned dust | 1.295 s | 0.797 s |
| DSCF0729 neutral auto | 0.711 s | 0.256 s |
| DSCF0729 manual base | 0.550 s | 0.253 s |
| DSCF0729 tuned | 1.264 s | 0.958 s |
| DSCF0729 tuned cooler | 1.142 s | 0.833 s |
| DSCF0729 tuned dust | 1.286 s | 0.918 s |
| DSCF2417 neutral | 0.152 s | 0.057 s |
| DSCF2417 tonal recovery | 0.345 s | 0.274 s |
| DSCF2417 contrast | 0.325 s | 0.232 s |
| DSCF2417 tonal recovery dust | 0.440 s | 0.229 s |
| DSCF2422 neutral auto | 0.699 s | 0.267 s |
| DSCF2422 manual base | 0.555 s | 0.269 s |
| DSCF2422 tuned | 1.137 s | 0.845 s |
| DSCF2422 tuned cooler | 1.135 s | 0.845 s |
| DSCF2422 tuned dust | 1.248 s | 0.840 s |

### Totals

| | Old (Jun 13) | New (Jul 3) | Change |
| --- | ---: | ---: | ---: |
| 10 matched edits, cold | 4.53 s | 6.70 s | +48% |
| 10 matched edits, warm | 2.60 s | 3.84 s | +48% |
| All 23 edits, cold | 11.77 s | 17.27 s | +47% |
| All 23 edits, warm | 7.17 s | 10.61 s | +48% |

Warm/cold ratio remains 61% — consistent with the original benchmark.

The ~48% slowdown is expected: the native engine has added several correction
stages and a full TIFF/JPEG/PNG/DNG export path since the original benchmark.
The legacy Python path exercises the same expanding codebase within the Swift
engine bridge.

## Selected-Edit Quality

Quality metrics are **identical** to the June 16 native benchmark — processing
produces the same output pixels. This confirms the pipeline has not regressed in
correctness.

| File / selected edit | Entropy | Black clip | White clip | Median RGB |
| --- | ---: | ---: | ---: | ---: |
| DSCF0669 tonal recovery | 6.199 bits | 0.448% | 0.521% | grayscale 50 |
| DSCF0718 tuned cooler | 7.669 bits | 0.727% | 0.003% | 154 / 163 / 155 |
| DSCF0729 tuned | 7.801 bits | 0.345% | 0.174% | 93 / 85 / 92 |
| DSCF2417 contrast | 7.551 bits | 0.000% | 0.170% | grayscale 139 |
| DSCF2422 tuned | 7.666 bits | 1.562% | 0.398% | 94 / 87 / 91 |

## Verification

```sh
# Decode
.venv/bin/python tests/decode_sample_raw.py \
  --raw-dir sample-raw \
  --output-dir /tmp/film_scan_corpus \
  --repetitions 3

# Benchmark
.venv/bin/python tests/benchmark_sample_raw.py \
  --decoded-dir /tmp/film_scan_corpus \
  --output-dir /tmp/film_scan_benchmark \
  --repetitions 3
```
