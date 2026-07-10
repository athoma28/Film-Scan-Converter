# 40 MP Native Export Benchmark

`FilmScanExportBenchmark` measures the production engine's decode, processing,
geometry, pixel-packing, and writer path for full-resolution RAW export. It is
intended to identify the dominant stage before implementation changes are made.
It is not a complete app-path benchmark: stored-settings resolution, automatic
classification, flat-field lookup, destination reservation, queue management,
and app-level cancellation/error reporting remain outside this executable.
The production app now supplies separate correlated signposts from queue wait
through cleanup; use Instruments alongside this executable when measuring the
whole workflow. Destination reservation remains app-only work outside the
engine benchmark and is not yet a separately timed interval.

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
These engine-level readings still do not replace app preview-cache measurement
or correlated app-path traces.

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
change that dominant-stage conclusion. Further engine optimization waits on
the remaining app-path latency evidence.

## Compact TIFF Packing Optimization

TIFF previously built a padded 64-bit RGBA `CGImage` buffer even though the
writer emits three 16-bit RGB channels. The production TIFF path now builds a
48-bit RGB buffer directly; PNG deliberately keeps its explicit RGBA layout.
For a 7752 x 5184 image, the packed intermediate fell from 321,490,944 bytes to
241,118,208 bytes, a 25% or 80,372,736-byte reduction.

The controlled `DSCF0669.RAF` before/after run reduced packing from 0.0268 to
0.0200 seconds (25.6%); across the ten-file confirmation, median packing fell
from 0.02973 to 0.02288 seconds (23.0%). Total export remains decode-dominated,
so no broader latency claim is warranted. The output remained 179,226,416 bytes with SHA-256
`e809f0ab4431336d6092e8828e2ad9d8e399baac9c3cbf216b1ae01494189a75`.
The ten-file confirmation preserved every prior TIFF byte count and hash.

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
engine-level question; app preview-cache measurement remains open.

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

## Next Run Cycle

Run these milestones in order so each optimization decision has a measured
input and a regression gate:

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
3. **App-path coverage.** Instrumentation complete. Each export item carries one
   correlation ID across queue wait, settings/classification resolution, decode,
   flat-field lookup, correction, crop/perspective/frame geometry,
   write/finalize, and cleanup. Loading also spans thumbnail or bounded standard
   preview decode, first corrected pixels, and authoritative replacement. Next,
   capture Instruments traces for a default power-law correction, density plus
   flat field, and a heavily edited crop/perspective/frame case.
4. **Memory envelope.** Engine gate complete. The corrected ten-file report
   records physical footprint, peak physical footprint, reusable bytes, legacy
   resident size, and default-zone statistics. Post-release physical footprint
   fell from 52.74 MB to 42.78 MB and peak stayed at 686.11 MB; the prior RSS
   growth was reclaimable allocator memory. Next measure app preview-cache
   depths 2, 8, and 32 with the same physical-footprint contract.
5. **Large-file handling.** Record p50/p95 for first corrected provisional
   pixels, authoritative replacement, cached next-file switching, uncached
   switching, and rapid-selection queue drain. Record peak memory for the same
   runs.
6. **Optimization slice.** Two safe secondary-stage slices are complete:
   multicore fused power-law correction is 74.9% faster at the measured median,
   and compact TIFF packing removes 80.37 MB while cutting the ten-file median
   interval 23.0%. Both preserve deterministic output bytes and hashes.
   Do not substitute a one-pass X-Trans quality mode; defer further engine work
   until the remaining app measurements expose a dominant seam.
7. **Batch confirmation.** Engine confirmation complete for ten sequential
   TIFF exports, including output contracts and physical memory. The remaining
   app-path run must add cancellation latency, queue timing, preview-cache
   effects, and post-batch physical footprint.
