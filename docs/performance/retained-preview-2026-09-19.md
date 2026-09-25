# Retained-preview performance follow-up

September 19, 2026. The measurements in this follow-up use the working tree
based on `c4ad5ba`, including the existing Film Base/LookRecipe, preset,
preview-retention, and two-worker RAW-scheduler changes. They do not compare
against that commit's original implementation or the September 14/16 workloads.

## Avoiding rejected speculative decodes

When a cache with a two-file limit retains A and B, selecting B makes C the next
lookahead candidate. Previously the app decoded C and created its renderer before
rejecting it because A and B already filled the cache. Repeated visits could
repeat this unused work. The same condition occurs at larger configured limits
after more photographs have been visited.

The app now checks count capacity, exhausted byte capacity, memory pressure, and
export state before submitting a speculative preview-tier decode. Replacement
tiers subtract the existing entry's source and reserved display bytes. Exact
post-decode admission remains necessary because the final allocation size is not
known beforehand. Speculation still cannot evict retained photographs; selecting
an uncached photograph still performs its foreground load and normal LRU eviction.

The new regressions cover rejected lookahead, resuming after a larger cache
limit, foreground loading into a full cache, and an exhausted byte budget.
Additional scheduler tests cover a selected request arriving while a neighbour
is running, both with a free worker and with both workers occupied. A RAW
lookahead assertion now accepts a completed full preview if its speculative
upgrade finishes before the asynchronous test resumes.

## Measurement contract

`AppPathPerformanceTests` runs each phase in a separate app model. It cancels
selection work, waits for stack analysis, drops the model, verifies weak-reference
release, and removes that phase's preferences before continuing. This avoids
overlapping unfinished work from prior samples.

- First/cached/uncached/rapid navigation timings stop at app-model publication.
  They do not include physical display presentation or native input delivery.
- Depths 2, 8, and 32 report the initial bounded lookahead population and actual
  source tiers. They do not claim that those caches are fully populated or that
  later full-resolution speculation has settled.
- Retained navigation first warms two full-sensor sources and both corrected
  rasters. It records revisit latency, full-decode/correction/cache-hit counts,
  1,000 viewport-demand updates, and physical footprint after background work
  and statistics settle and after model release.
- The saturated-cache case warms A and B while C remains uncached. Each timed
  visit to B records publication and background-drain latency plus speculative
  tier submission count; the return to A is outside the timed sample.
- Submission counts include requests later cancelled in the scheduler. They
  are not native-decode completion counts. Three repetitions are descriptive
  samples, not a reliable population-tail estimate.

The switch waits poll at 5 ms intervals, so differences near that interval are
not evidence of faster screen presentation. The retained phases require enough
cache budget for both full sessions; larger sensors or lower-memory machines
may not satisfy this workload's prerequisites.

Full rendered images and private scans stay in ignored directories. This work
does not modify processing math, quality tiers, color defaults, or RAW fixtures.

## Results

The [raw before/after report](retained-preview-measurements-2026-09-19.json)
contains every sample, input hashes, source/harness digests, cache source tiers,
and physical-footprint readings. Both isolated release processes used the same
harness and ten-file corpus on an Apple M4 Pro (Mac16,7, 14 CPU cores, 48 GiB
RAM), macOS 15.7.9 (24G830), Swift 6.1.2, and LibRaw 0.22.2. Only `AppModel.swift`
changed in production sources between runs. Trials ran before then after, rather
than alternating, and did not force a cold filesystem cache.

The saturated cache retained `aesthetic-test/DSCF3233.RAF` and `DSCF3723.RAF`;
`DSCF3767.RAF` was the uncached next neighbour.

| Measurement | Before | After |
|---|---:|---:|
| Unusable lookahead submissions across three revisits | 1, 1, 1 | **0, 0, 0** |
| Saturated-cache background drain, median | 1,062.01 ms | **6.50 ms** |
| Saturated-cache background drain, individual samples | 1,062.01 / 1,261.63 / 1,054.34 ms | 12.88 / 6.50 / 6.43 ms |
| Saturated-cache retained publication, median | 6.53 ms | 6.46 ms |
| Two-file retained navigation, six revisits, median | 6.56 ms | 6.50 ms |
| Full decodes / corrections during retained navigation and 1,000 viewport updates | 0 / 0 | 0 / 0 |
| Corrected-raster cache hits during six revisits | 6 | 6 |
| First corrected publication, median of three files | 586.87 ms | 580.64 ms |
| Cached lookahead-source switch, median | 25.11 ms | 26.17 ms |
| Uncached switch, median | 470.67 ms | 369.49 ms |
| Rapid-selection final publication, median | 377.51 ms | 339.02 ms |

The supported speed claim is the removal of unused background decoding in the
saturated-cache scenario. Cached publication remains near the polling floor.
The other navigation samples provide fresh observations, but this small sequential
cohort does not establish a general first-paint or uncached-navigation improvement.
Warmup and cached-source switching still include real decode/correction work.

Each retained pair accounted for 1,455.43 MiB of source, renderer, and display
storage against the 3 GiB logical cache budget. Settled physical footprint was
1,041.68 MiB before and 1,111.50 MiB after; after that model's verified release it
was 120.66 and 113.86 MiB. Whole-process peak was 1,272.64 and 1,188.96 MiB;
final footprint after the last model release was 40.69 and 191.13 MiB. These
framework/allocator-dependent measurements do **not** establish a memory reduction.
The report keeps reusable bytes separate from physical footprint.

At configured depths 2, 8, and 32, the initial lookahead samples contained 2, 4,
and 4 sessions. The selected source could still be inspect resolution or could
already have reached full resolution, so those samples are not interchangeable
cache-capacity measurements. Larger retained rolls and sustained memory-pressure
behavior remain outside this cohort.

## Regression findings

The first complete release run, with the representative roll enabled, reported
667 tests: 652 passing records, 13 opt-in skips, and two failed tests (four issues)
in 395.679 seconds. The new admission and two-worker scheduler cases passed.

- The retained-full-preview test timed out at its first wait. Earlier RAW tests
  returned with live preview tasks, despite suite serialization. Four RAW tests
  now use isolated preferences, cancel selection work, and verify model release
  before the next test; failures print source/status/work-counter diagnostics.
- The opt-in roll fixture initialized its exception with the default Original
  (`cropOnly`) base. Current look transfer preserves that base, so exposure edits
  did not change preview/export pixels. The fixture now explicitly chooses C-41
  and asserts its inversion identity remains unchanged. Both existing pixel
  inequality checks remain in place. Its progress print no longer claims a pass
  when nonfatal assertions can still have failed.

These changes repair test isolation and align the roll setup with current
Film Base/LookRecipe contracts. They do not modify production color behavior or
weaken the rendering assertions.

The focused release rerun passed all **98 tests in 53.762 seconds**, including
the retained RAW previews, admission and scheduler cases, and the real three-frame
roll with preview/export pixel changes, retained-decode re-export, independent
TIFF inspection, cleanup, and unchanged source hashes.

The final complete release run passed in **289.942 seconds**: **667 tests
reported, 654 passing records, 13 opt-in skips, zero issues**, with
`RUN_REPRESENTATIVE_ROLL_TESTS=1`. Both previously failing tests passed in this
full run. Suite duration is not an application performance measurement.

Additional checks passed: 2,725 CPU/Metal comparisons with zero render failures
and maximum channel error 2/255, both C/C++ RAW compatibility checks, strict
formatting of the six Swift files touched here, `git diff --check`, and the
strict MkDocs build. The comparator's existing grid is not complete factory-look
or photographic coverage. The other opt-in performance/export studies, packaging,
legacy Python suite, hands-on interaction, and full color studies were not rerun.

## Reproduction

Run from the repository root with normal macOS graphics access. Keep before and
after reports in separate fresh output files and run performance processes
sequentially. The benchmark cohort is the first ten root-relative RAF paths in
the current corpus, recorded in the report; corpus changes can change that cohort.

```sh
mkdir -p dist/performance-2026-09-19
RUN_APP_PATH_PERFORMANCE_TESTS=1 \
APP_PATH_BENCHMARK_REPETITIONS=3 \
APP_PATH_BENCHMARK_OUTPUT="$PWD/dist/performance-2026-09-19/app-path-after.json" \
CLANG_MODULE_CACHE_PATH=/tmp/fsc-speed-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/fsc-speed-swift \
swift test --disable-sandbox -c release --package-path native/FilmScanEngine \
  --jobs 2 --no-parallel --filter AppPathPerformanceTests

RUN_REPRESENTATIVE_ROLL_TESTS=1 \
CLANG_MODULE_CACHE_PATH=/tmp/fsc-speed-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/fsc-speed-swift \
swift test --skip-build -c release --package-path native/FilmScanEngine \
  --no-parallel
```
