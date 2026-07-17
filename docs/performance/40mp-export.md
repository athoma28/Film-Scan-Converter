# 40 MP Native Export Benchmark

`FilmScanExportBenchmark` measures the production engine's decode, processing,
geometry, pixel-packing, and writer path for full-resolution RAW export. It is
intended to identify the dominant stage before implementation changes are made.
It is not a complete app-path benchmark: stored-settings resolution, automatic
classification, flat-field lookup, destination reservation, queue management,
and app-level cancellation/error reporting remain outside this executable.
The production app supplies separate correlated signposts from queue wait
through cleanup. Release-mode app-path benchmarks now cover selection and
preview-cache latency plus a ten-job sequential export and active-decode
cancellation without requiring Instruments; Instruments remains useful for
stage-level traces. Destination reservation is included in the app-path total
but is not reported as a separate interval.

Interactive loading and export have separate image contracts. Browsing and
editing use a 1000px embedded-RAW or ImageIO preview with a 256px analysis
proxy. The preview cache never owns full-resolution decoded files. Export
always decodes on demand; camera-scan RAW export retains the final-quality
three-pass X-Trans path measured below.

App cancellation is cooperative at safe stage boundaries: starting an export
cancels speculative lookahead decoding, cancellation prevents completed decode
or correction work from advancing to the next stage, and unstarted batch items
receive explicit cancelled results. Synchronous LibRaw and writer calls still
finish their active call, so the batch run must measure observed cancellation
latency rather than claiming immediate interruption.

## Disk-Space Contract

Only one generated export exists at a time. After each measured repetition the
benchmark:

1. reads the completed output in 1 MiB chunks to calculate SHA-256;
2. records its byte count;
3. deletes it and verifies that it is gone; and
4. retains only the compact JSON sample.

The scratch directory is also removed on success or failure. This contract
applies to single-file, multi-format, repeated, and `--all` corpus runs.

## Run

```sh
swift build -c release --package-path native/FilmScanEngine \
  --product FilmScanExportBenchmark

native/FilmScanEngine/.build/release/FilmScanExportBenchmark \
  sample-raw /tmp/film-scan-export.json 3 --file=DSCF0669.RAF
```

Options:

- `--formats=tiff,jpeg,png,dng` selects formats; all four are the default.
- `--file=NAME.raf` selects one representative source; otherwise the first RAF
  in lexical order is used.
- `--all` runs every RAF sequentially.
- `--limit=N` caps the selected corpus to its first `N` lexical RAFs. Use
  `--all --limit=10` for the bounded sequential-memory run.
- `--frame-percent=N` exercises frame allocation and geometry separately.

The first repetition is labelled `first-run`; later repetitions are labelled
`warm-filesystem-cache`. The benchmark does not purge macOS filesystem caches,
so “first-run” is not a guaranteed physically cold disk measurement.

The JSON report retains every sample and calculates median plus nearest-rank p95
for total time, every export stage, and every decode substage. It also records
the writer's packed-pixel byte count. With the current three-repetition gate,
p95 is the slowest sample; it is a useful bounded-run tail marker, not a stable
population estimate.

Each sample records Mach `resident_size` and physical footprint after decode,
after correction, after writing, and after the sample function has returned and
all full-resolution image references have been released. It also records the
process-lifetime peak physical footprint and post-release reusable bytes.
Physical footprint is the resource-safety gate. `ru_maxrss` and resident size
include clean reusable pages and can rise even when macOS has already reclaimed
their physical cost.

Each post-release sample retains `heapStatisticsAfterRelease`, a default-zone
live/reserved snapshot, as a secondary classification aid. All-zone `vmmap`
snapshots of the sequential run identified the apparent growth as
`MALLOC_LARGE_REUSABLE` and empty allocator regions: those pages increased the
resident count without increasing dirty live memory or physical footprint.
These engine-level readings complement the completed app preview-cache depth,
sequential-export, cancellation, and correlated stage-level app-path evidence.

## App-Path Preview Baseline

The opt-in `AppPathPerformanceTests` benchmark exercises the real `AppModel`,
embedded-RAW thumbnail extraction, 1000px display source, 256px analysis
source, production preview renderer, lookahead cache, and latest-selection-wins
drain. It records nearest-rank p50/p95 latency plus Mach physical footprint and
the maximum logical preview-cache byte count. It writes no exports.

Run it in release mode with writable Swift caches:

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

On 2026-07-11, a Mac16,7 ran three rotated repetitions over six local RAFs:

| App-path interval | p50 | nearest-rank p95 |
|---|---:|---:|
| First corrected paint | 50.71 ms | 63.72 ms |
| Cached next-file switch | 14.57 ms | 83.98 ms |
| Uncached switch | 126.32 ms | 126.32 ms |
| Six-file rapid-selection drain | 81.55 ms | 133.77 ms |

The largest observed two-file preview cache was 8,529,312 bytes. Process
physical footprint ended at 28,787,792 bytes after a 155,567,136-byte
process-lifetime peak; reusable bytes were 376,029,184 and are not counted as
live physical memory. With three repetitions, p95 is the slowest sample, so
these are compact regression baselines rather than population-tail claims.
The bounded preview architecture has no normal authoritative replacement
interval: browsing keeps the preview source, while export independently decodes
the full-resolution camera RAW.

The 2026-07-14 follow-up extended the same release benchmark with cache-depth
samples. Each sample records configured depth, realized sessions, logical cache
bytes, fill time, and Mach physical footprint before fill, at capacity, and
after model release:

| Configured depth | Realized sessions | Logical cache | Fill time | Physical at capacity | Physical after release |
|---:|---:|---:|---:|---:|---:|
| 2 | 2 of 6 | 8.53 MB | 95.62 ms | 40.04 MB | 27.82 MB |
| 8 | 6 of 6 | 25.59 MB | 270.05 ms | 76.92 MB | 26.23 MB |
| 32 | 6 of 6 | 25.59 MB | 251.41 ms | 44.19 MB | 26.49 MB |

The local corpus has six RAFs, so depths 8 and 32 intentionally report the same
realized population; this does not claim a fully populated 32-file cache. The
depth samples run sequentially in one process, and later samples reuse allocator
pages. Therefore the at-capacity physical-footprint values are diagnostic, not
a monotonic depth comparison. Logical cache bytes show the deterministic
scaling, while the roughly 26-28 MB post-release readings show no sustained
per-depth physical-footprint growth.

## App-Path Sequential Export And Cancellation Baseline

`AppPathExportPerformanceTests` exercises the production `AppModel` queue,
destination reservation, stored/default settings resolution, full-resolution
camera-scan decode, correction, geometry, TIFF write, progress state, cleanup,
and cancellation reporting. The local corpus currently contains six RAFs, so
the benchmark starts Export All and appends the first four files again through
the duplicate-friendly queue contract to reach ten independent export jobs.

Run the release benchmark with writable Swift caches:

```sh
RUN_APP_PATH_EXPORT_PERFORMANCE_TESTS=1 \
APP_PATH_EXPORT_BENCHMARK_OUTPUT=/tmp/film-scan-app-path-export.json \
CLANG_MODULE_CACHE_PATH=/tmp/film-scan-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/film-scan-swiftpm-cache \
swift test --disable-sandbox -c release \
  --package-path native/FilmScanEngine --no-parallel \
  --filter AppPathExportPerformanceTests
```

On 2026-07-15, a Mac16,7 completed the ten TIFF jobs in 225.213 seconds.
Per-job completion time was 22.521 seconds on average, with a 22.567-second p50
and 22.804-second nearest-rank p95. With ten samples, p95 is the slowest job and
is a compact run marker rather than a population-tail estimate.

| App-path batch evidence | Result |
|---|---:|
| Unique RAFs / queued jobs | 6 / 10 |
| Per-job p50 / nearest-rank p95 | 22.57 / 22.80 s |
| Physical footprint at progress observations | 71.03–74.14 MB |
| First-to-last observed footprint change | +3.11 MB |
| Physical footprint after model release | 61.41 MB |
| Process-lifetime peak physical footprint | 714.15 MB |
| Temporary outputs removed / remaining | 10 / 0 |

Progress observations may overlap the next decode, so their narrow band is a
bounded-growth diagnostic rather than a clean after-each-file release sample.
The post-run and post-model-release readings are the live-memory gates. The
sequence had no export errors and shows no runaway per-file growth.

The same process then started another ten-job queue and requested cancellation
250 ms into its first full-resolution decode. Cancellation reached the next
safe boundary in 21.573 seconds, reported `Export cancelled after 1 of 10
images.`, wrote no output, and returned from 67.24 MB at completion to 59.62 MB
after model release. This is intentionally not an instant-cancellation claim:
the active synchronous LibRaw call finishes before the task observes
cancellation and prevents correction, geometry, write, and later queue items.

## Sequential Memory Baseline

On 2026-07-09, the corrected release executable ran one TIFF export for each of
the first ten lexical RAFs with `--all --limit=10 --formats=tiff`. All ten
outputs were hashed, deleted, and confirmed absent. Post-release physical
footprint fell from 52.74 MB to 42.78 MB and process-lifetime peak physical
footprint stayed fixed at 686.11 MB. The engine sequential-memory gate passes.

| File | Physical footprint after release | Peak physical footprint | Reusable bytes after release | Legacy resident size |
|---|---:|---:|---:|---:|
| DSCF0669.RAF | 52.74 MB | 686.11 MB | 1.069 GB | 1.132 GB |
| DSCF0718.RAF | 51.84 MB | 686.11 MB | 1.114 GB | 1.179 GB |
| DSCF0729.RAF | 44.17 MB | 686.11 MB | 1.156 GB | 1.217 GB |
| DSCF2417.RAF | 44.12 MB | 686.11 MB | 1.293 GB | 1.357 GB |
| DSCF2422.RAF | 44.30 MB | 686.11 MB | 1.314 GB | 1.381 GB |
| DSCF2433.RAF | 43.47 MB | 686.11 MB | 1.344 GB | 1.414 GB |
| DSCF2437.RAF | 43.62 MB | 686.11 MB | 1.345 GB | 1.418 GB |
| DSCF2440.RAF | 42.57 MB | 686.11 MB | 1.346 GB | 1.422 GB |
| DSCF2471.RAF | 42.60 MB | 686.11 MB | 1.353 GB | 1.431 GB |
| DSCF2473.RAF | 42.78 MB | 686.11 MB | 1.467 GB | 1.549 GB |

The resident count still rises, but it follows reusable bytes almost exactly
while physical footprint remains flat. Treating resident size as live memory
created the earlier false failure. No allocator-pressure workaround belongs in
the production path for pages that macOS has already made reclaimable.

## Repeated Format Baseline

On 2026-07-09, the release executable completed the first repeated baseline:
three TIFF/JPEG/PNG/DNG runs for `DSCF0669.RAF` and three TIFF runs for each of
two additional 40.19 MP RAFs. The engine's default TIFF format is used for the
corpus extension. All 18 exports were hashed, deleted immediately, and
confirmed absent before the report was written.

| Source | Format | Total p50 / p95 | Decode p50 / p95 | Correction p50 / p95 | Write p50 / p95 |
|---|---|---:|---:|---:|---:|
| DSCF0669.RAF | TIFF | 24.789 / 24.893 s | 21.677 / 21.774 s | 0.764 / 0.850 s | 2.286 / 2.354 s |
| DSCF0669.RAF | JPEG | 22.434 / 23.080 s | 21.492 / 21.859 s | 0.763 / 1.029 s | 0.167 / 0.175 s |
| DSCF0669.RAF | PNG | 27.373 / 27.410 s | 21.447 / 21.481 s | 0.758 / 0.765 s | 5.139 / 5.146 s |
| DSCF0669.RAF | DNG | 22.682 / 22.695 s | 21.637 / 21.851 s | 0.796 / 0.989 s | 0.053 / 0.068 s |
| DSCF0718.RAF | TIFF | 25.612 / 26.200 s | 23.502 / 23.889 s | 0.651 / 0.806 s | 1.449 / 1.479 s |
| DSCF0729.RAF | TIFF | 16.719 / 16.842 s | 15.332 / 15.409 s | 0.438 / 0.442 s | 0.952 / 0.968 s |

The range across RAFs confirms that final-quality camera-scan decode remains
the dominant stage and varies materially with source content. PNG is writer
bound; TIFF's LZW finalize is its only substantial non-decode component. The
compact-buffer slice below reduces writer memory traffic without claiming to
change that dominant-stage conclusion. The app-path measurement cycle is now
complete; further engine optimization waits on a measured user-visible or
resource-safety regression.

## Compact And Parallel Export Packing

TIFF previously built a padded 64-bit RGBA `CGImage` buffer even though the
writer emits three 16-bit RGB channels. The production TIFF path now builds a
48-bit RGB buffer directly; the follow-up below applies the same compact layout
to PNG.
For a 7752 x 5184 image, the packed intermediate fell from 321,490,944 bytes to
241,118,208 bytes, a 25% or 80,372,736-byte reduction.

The controlled `DSCF0669.RAF` before/after run reduced packing from 0.0268 to
0.0200 seconds (25.6%); across the ten-file confirmation, median packing fell
from 0.02973 to 0.02288 seconds (23.0%). Total export remains decode-dominated,
so no broader latency claim is warranted. The output remained 179,226,416 bytes with SHA-256
`e809f0ab4431336d6092e8828e2ad9d8e399baac9c3cbf216b1ae01494189a75`.
The ten-file confirmation preserved every prior TIFF byte count and hash.

The follow-up applies the same bounded packing strategy to every writer. Pixel
ranges are independent, so images of at least one megapixel now use at most
eight workers for BGR-to-RGB conversion. TIFF and DNG retain their 48-bit RGB
buffers; JPEG moves from padded 32-bit RGBA to 24-bit RGB, and PNG moves from
padded 64-bit RGBA to 48-bit RGB. At 7752 x 5184 this removes 40,186,368 bytes
from the JPEG intermediate and 80,372,736 bytes from PNG.

On 2026-07-11, one release-mode before/after run used the same
`DSCF2819.RAF`, settings, and production writer path. All outputs were hashed
and removed immediately. The table isolates the pack and writer intervals;
full export remained dominated by the separately measured three-pass X-Trans
decode.

| Format | Packed bytes before -> after | Pack before -> after | Pack + finalize before -> after |
|---|---:|---:|---:|
| TIFF | 241,118,208 -> 241,118,208 | 20.18 -> 11.54 ms (-42.8%) | 1.6462 -> 1.6215 s (-1.5%) |
| JPEG | 160,745,472 -> 120,559,104 | 14.22 -> 10.67 ms (-24.9%) | 0.2366 -> 0.2310 s (-2.4%) |
| PNG | 321,490,944 -> 241,118,208 | 24.75 -> 19.39 ms (-21.7%) | 3.8790 -> 3.7844 s (-2.4%) |
| DNG | 241,118,208 -> 241,118,208 | 23.81 -> 19.60 ms (-17.7%) | 0.0907 -> 0.0635 s (-30.0%) |

The output byte count and SHA-256 were identical before and after for each of
the four formats. This is a single controlled A/B, so the percentages are
bounded-run evidence rather than stable population estimates. The large-image
packing regression also crosses worker boundaries and verifies exact 8-bit and
16-bit channel values; small images stay on a one-worker path.

## Initial Smoke Measurement

On 2026-07-06, one release-mode TIFF repetition using `DSCF0669.RAF` produced:

| Stage | Seconds | Share |
|---|---:|---:|
| Full-resolution camera-scan decode | 21.506 | 78.2% |
| Film-negative correction | 3.682 | 13.4% |
| Geometry, no frame requested | < 0.001 | < 0.1% |
| 16-bit RGBA pixel packing | 0.029 | 0.1% |
| LZW TIFF encoding/finalization | 2.289 | 8.3% |
| Total | 27.505 | 100% |

The source and output were 7752 × 5184 (40.19 MP), the temporary TIFF was
179,226,416 bytes, process-lifetime peak RSS was 1,201,078,272 bytes, and the
report recorded `outputRemovedAfterRun: true`. This single repetition is a
smoke result, not the repeated baseline. It shows that the camera-scan decode is
the first stage to investigate; it does not yet justify a decode rewrite.

The first decomposed release run on the same file completed in 27.685 seconds.
Its 21.678-second outer decode broke down as follows:

| Decode substage | Seconds | Decode share |
|---|---:|---:|
| RAW open and metadata | 0.001 | < 0.1% |
| Sensor unpack | 1.342 | 6.2% |
| Three-pass X-Trans demosaic | 19.710 | 90.9% |
| Remaining LibRaw post-processing | 0.378 | 1.7% |
| Processed-image creation | 0.057 | 0.3% |
| ISO-adaptive policy | 0.137 | 0.6% |
| Swift copy/swizzle | 0.049 | 0.2% |

The substage sum reconciles with the outer decode measurement within timing
overhead. Three-pass X-Trans demosaic is therefore the dominant camera-scan
stage. Reducing it to one pass would change the final-quality export contract;
it is not an acceptable performance shortcut. Any optimization of this stage
must preserve the three-pass quality guard and full-resolution output.

## First Correction Optimization

The next safe stage was the 3.685-second fused power-law correction. Images at
least one megapixel now divide independent pixel ranges across at most eight CPU
workers. Smaller images remain serial so the bounded interactive path does not
pay dispatch overhead. The arithmetic, lookup table, and output conversion are
unchanged, and a large-image regression compares every output pixel with the
authoritative render-ready-linear plus display path.

Two post-change release repetitions on `DSCF0669.RAF` measured correction at
0.967 and 0.885 seconds, a 0.926-second median and 74.9% improvement over the
3.685-second baseline. Median total TIFF export was 24.874 seconds, 10.1% below
the 27.685-second decomposed baseline even though demosaic time was unchanged.
Both outputs were 179,226,416 bytes with SHA-256
`e809f0ab4431336d6092e8828e2ad9d8e399baac9c3cbf216b1ae01494189a75`.
First-run peak RSS was effectively unchanged (1,210,269,696 versus
1,211,367,424 bytes). The later physical-footprint instrumentation supersedes
RSS as the live-memory gate and the corrected ten-file sequence closes that
engine-level question. The later app-path benchmark closes the local six-RAF
preview-cache depth comparison.

## Decode-Baseline Correction

The 21.506-second result above is the full-resolution
`rawTherapeeCameraScan` profile. It includes the camera-scan demosaic and ISO
processing policy. The approximately 7.25-second full-resolution result in
[`native-raw-benchmark.md`](../development/native-raw-benchmark.md) uses the
frozen `rawPyCompatibility` profile and PPG interpolation. Those numbers are
not an apples-to-apples regression comparison and must not share one performance
gate.

Use two explicit contracts:

1. **Compatibility decode:** compare `rawPyCompatibility` with RawPy on the same
   file, stage set, LibRaw settings, hardware, and exact-output fixture.
2. **Camera-scan decode:** measure `rawTherapeeCameraScan` against its own
   release baseline and quality fixtures. Track its unpack, demosaic, color and
   tone conversion, ISO denoise/sharpen, processed-image creation, and Swift
   copy/swizzle costs separately before optimizing it.

## Closed Run Cycle

These milestones were run in order so each optimization decision had a measured
input and a regression gate. The cycle is now closed; retain these results as
regression evidence and reopen optimization only for a measured user-visible or
resource-safety problem.

1. **Repeated format baseline.** Complete. Three TIFF/JPEG/PNG/DNG runs for
   `DSCF0669.RAF` plus three TIFF runs for `DSCF0718.RAF` and `DSCF0729.RAF`
   now have per-sample, median, and nearest-rank p95 timing. Keep `first-run`
   as a repetition label; do not call it physically cold unless the storage
   cache was independently controlled.
2. **Decode-stage decomposition.** Complete. Release timing now covers RAW
   open/unpack, demosaic, remaining `dcraw_process` work, ISO policy,
   processed-image creation, and the Swift copy/swizzle boundary. On the first
   decomposed run, three-pass X-Trans demosaic consumed 19.710 of 21.678 decode
   seconds. Keep these fields in every repeated/corpus report.
3. **App-path coverage.** Instrumentation and the first reproducible latency
   baseline are complete. Each export item carries one
   correlation ID across queue wait, settings/classification resolution, decode,
   flat-field lookup, correction, crop/perspective/frame geometry,
   write/finalize, and cleanup. Loading spans selection-to-first-corrected-paint,
   thumbnail extraction, 1000px conversion, and bounded analysis. The benchmark
   records first paint, cached/uncached switching, rapid-selection drain, cache
   bytes, and physical footprint. Use Instruments only when a later regression
   needs deeper render-stage attribution.
4. **Memory envelope.** Engine, preview-cache, and app-export gates complete. The corrected
   ten-file report
   records physical footprint, peak physical footprint, reusable bytes, legacy
   resident size, and default-zone statistics. Post-release physical footprint
   fell from 52.74 MB to 42.78 MB and peak stayed at 686.11 MB; the prior RSS
   growth was reclaimable allocator memory. The app benchmark now samples
   preview-cache depths 2, 8, and 32 with the same physical-footprint contract;
   its six-file corpus saturates the latter two depths at six sessions and
   returns to roughly 26-28 MB after each model release. The ten-job app export
   stayed within a 71.03–74.14 MB observed band and returned to 61.41 MB after
   model release; the following cancellation run returned to 59.62 MB.
5. **Large-file handling.** First corrected paint, cached and uncached
   switching, rapid-selection drain, ten-job sequential export, active-decode
   cancellation, and process memory now have reproducible release baselines.
   The bounded browsing contract has no authoritative
   replacement stage. Preview-cache depth sampling is complete for the local
   six-RAF corpus; retain the realized-session count in future larger-corpus
   reports rather than implying depth 32 was fully populated here.
6. **Optimization slice.** Two safe secondary-stage slices are complete:
   multicore fused power-law correction is 74.9% faster at the measured median,
   and compact TIFF packing removes 80.37 MB while cutting the ten-file median
   interval 23.0%. Both preserve deterministic output bytes and hashes.
   Do not substitute a one-pass X-Trans quality mode; defer further engine work
   until a later measurement exposes a user-visible or resource-safety problem.
7. **Batch confirmation.** Complete. Engine confirmation covers ten sequential
   TIFF exports with output contracts and physical memory. The app-path run adds
   ten queue completions, preview-cache effects, post-batch physical footprint,
   per-run output removal, and measured safe-boundary cancellation latency.
