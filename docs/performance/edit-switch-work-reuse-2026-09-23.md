# Editing and retained-image work reuse — September 23, 2026

This follow-up removes repeated diagnostics and duplicate edit submissions from
the native app. Rendering, image resolution, color parameters, RAW decoding,
cache admission, and export processing are unchanged.

## Changes

- Each immutable corrected raster now owns lazy, memoized statistics. Cached
  navigation publishes the retained statistics with the image instead of
  resampling identical pixels on a utility worker. The memo releases its compute
  closure after resolution. Publication uses a nonblocking read; concurrent
  resolutions compute once, and source/revision checks still reject stale work.
- Ending a gesture whose raster is already complete refreshes delayed statistics
  directly. A complete render still in flight supplies its own final sample.
  This avoids an extra render request and, when the last correction is running,
  duplicate correction work. Proxy/viewport gestures still queue exact full-source
  refinement with current parameters.
- A color-wheel pointer sample sets hue and strength in one model mutation,
  replacing up to two settings updates and render submissions with one. Double
  click preserves hue and clears strength. Persistence and one undo step per drag
  are preserved.

## Bounded statistics measurement

The release probe decodes `fuji400-fresh/DSCF2833.RAF` once through the production
one-pass camera-scan path, renders C-41 / Clean Invert / photographic tone v2,
then compares repeated statistics sampling with memoized retrieval on the **same
7752×5184 corrected raster**. Analysis is the immutable 256px sensor image.
The input SHA-256 is
`c71a348038f397743360ca41a2ac099f51b81c1dd81e319b39e39a05711f2fe7`.

Two direct warmups and the initial memoized computation are excluded from eight
counterbalanced timed pairs. All statistics agree exactly; no images are written.

| Operation | Median | Range |
|---|---:|---:|
| Recompute bounded diagnostics from the full raster | 3.142 ms | 2.911–3.309 ms |
| Retrieve the resolved statistics | <0.001 ms | <0.001 ms |

The saved report retains all raw timings. Cached measurements approach timer
resolution, so no large speedup ratio is claimed. This removes about 3.14 ms of
background work per repeated sample on this frame; it does **not** measure an
equivalent reduction in visible switch latency. Initial diagnostics still cost
one sample, and new corrected pixels still require new statistics.

Collection used Mac16,7 / M4 Pro / 48 GiB RAM, macOS 15.7.9 (24G830), Swift 6.1.2,
and LibRaw 0.22.2. The checkout was `main` at
`fc63454e7d884fc0e9d272ff4f55ad93751227a2` plus the existing working-tree changes
and this follow-up. About 81 GiB disk space was available; the pre-run memory
query reported 90% free. Power reported AC with battery 85% discharging. No
cache purge, energy measurement, or thermal study was performed.

## App-path navigation guard

A separate three-repetition `AppPathPerformanceTests` release run passed all
three tests in 81.736 s using the first ten local `aesthetic-test` RAF paths.
The retained pair was DSCF3233 and DSCF3723. Both full-source rasters and their
statistics were warmed before six revisits and 1,000 settled viewport updates.

- Six corrected-raster cache hits; **zero additional full decodes, corrections,
  or statistics computations** across navigation and viewport changes.
- Retained publication samples were 6.897, 6.859, 7.053, 6.935, 6.830, and
  6.808 ms. Reported nearest-rank p50 was **6.859 ms**; including current
  statistics, p50 was **6.863 ms**. These are near the harness's 5 ms polling
  floor and are not native input/screen presentation measurements.
- Retained logical cache storage was 1,455.11 MiB within the 3,072 MiB budget.
  Physical footprint was 1,037.55 MiB settled and 268.50 MiB after model release.
  The complete process ended at 268.74 MiB with a cumulative peak of
  1,113.44 MiB. Reusable pages are reported separately in the JSON. This is a
  lifecycle guard, not a controlled memory-saving or long-duration leak claim.
- Saturated-cache revisits submitted zero speculative requests in all three
  samples. Publication was 6.811–6.848 ms; background drain was 6.814–32.112 ms.

The broader run also records first-publication samples of 244.35/759.27/773.72 ms,
cached-source first-correction samples of 25.54/31.96/28.49 ms, uncached-switch
samples of 933.57/1,139.94/527.35 ms, and rapid-selection drain samples of
2,591.78/431.75/485.23 ms. These phases include different decode/scheduler work
and remain variable. There is no controlled before/after app-latency comparison,
so this follow-up claims removal of repeated work, not an app-wide speedup.

## Verification and limits

The final focused release run passed **31 tests, zero issues or skips**, in
11.326 s. It covers publication while editing, stale source/geometry/comparison
rejection, memoization and concurrent sampling, cache/memory-pressure behavior,
viewport refinement, wheel events/history/persistence, and the 640-entry settings
store. The real-RAW app test also passed both GPU and CPU-fallback proxy edits
followed by full-resolution current-parameter refinement.

The 60-event exposure replay published 57 frames during the gesture, with no
extra release publication, final parameters persisted, a 14.31 ms longest
publication gap, and 6.25 ms final interaction-to-model-publication time. This
is a small committed PNG and programmatic 8 ms setters, not RAW input-to-screen
timing. The statistics run separately passed three tests and the app-path run
passed three. Strict formatting for the changed Swift files and
`git diff --check` passed.

One initial build overlapped a test-file edit and was discarded; the next test
fixture exceeded Swift's expression type-checking limit and was simplified.
An initial wheel test compared persisted parameters with transient live medians;
the corrected assertion verifies the exact wheel and every serializable field,
excluding only the medians that Codable intentionally omits. All three wheel
variants then passed. The timing runs used the same production and timing-harness
sources as final verification; only that wheel assertion changed before the
final test-binary rebuild. Both binary manifests are retained.

The complete native suite, standalone CPU/Metal comparator, exports, photographic
preference galleries, packaged-app gesture/presentation latency, sustained-roll
memory, and energy were not rerun. No processing math or preferred looks changed.

## Reproduction and evidence

Use release mode, normal macOS graphics access, and a fresh output directory.
The real-RAW opt-in requires the named local input and fails if it is missing.

```sh
mkdir -p dist/edit-switch-next
RUN_PREVIEW_STATISTICS_BENCHMARK=1 \
FSC_STATISTICS_BENCHMARK_OUTPUT="$PWD/dist/edit-switch-next/statistics.json" \
CLANG_MODULE_CACHE_PATH=/tmp/film-scan-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/film-scan-swiftpm-cache \
swift test --disable-sandbox -c release \
  --package-path native/FilmScanEngine --no-parallel \
  --filter PreviewStatisticsPerformanceTests
```

The [test guide](../../tests/README.md) lists the independent editing replay and
app-path navigation switches. Run timing processes sequentially, after builds.
The local evidence root is ignored
[`dist/edit-switch-performance-2026-09-23/`](../../dist/edit-switch-performance-2026-09-23/):
the statistics JSON/log, app-path JSON/log, regression logs, formatting result,
baseline app-source snapshots, and source/binary manifest.
