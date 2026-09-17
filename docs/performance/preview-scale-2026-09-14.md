# Full-resolution edit preview scaling

September 14, 2026. This follows the editing measurements and promotion gates in
the [performance research plan](research-directions-2026-09-12.md). It measures
the retained real-RAW renderer at the app's draft, inspect, and full-sensor tiers,
then implements a bounded interaction raster for continuous point-control edits.

## Outcome

Once a selected RAW has reached its full-sensor preview, an active slider,
curve, or color-wheel gesture now renders through a retained 2048px GPU proxy.
The proxy bitmap keeps the full corrected document size, so Fit, pan, 100%, and
overlay coordinates do not change when it publishes. Gesture release immediately
queues the same parameters against the full source; that exact refinement must
publish last.

The proxy is used only while an edit transaction is active, only for a selected
`.rawFull` session, and only when `StillPreviewRenderer` supports the current
parameters. Original comparison, measured-density processing, perspective,
straighten, automatic crop, and other CPU fallback cases keep their existing
full-source contract. Export is unchanged.

The full session retains an additional 2048 × 1370 RGB16 source and RGBA16
renderer backing: 16,834,560 plus 22,446,080 bytes, about 37.5 MiB combined.
Both are released with the selected full session. Cache accounting includes
them, although the selected full-resolution session remains outside the bounded
background-cache byte limit by design.

## Bounded A/B measurement

The release-mode probe decodes
`sample-raw/fuji400-fresh/DSCF2833.RAF` through the same camera-scan profile.
For each source it warms uncropped and fixed-manual-crop graphs, alternates their
order across three exposure values, creates RGBA8 output, and computes the same
bounded `CGImage` statistics used before app publication. Merely returning a
Core Image-backed `CGImage` did not force comparable work, so the statistics
consumer is deliberately inside every timed sample.

| Source | RGB16 source | Retained RGBA16 | Uncropped samples, median | Cropped samples, median |
|---|---:|---:|---:|---:|
| Draft, 594 × 396 | 1.35 MiB | 1.79 MiB | 3.47 / 3.26 / 3.22 ms; **3.26 ms** | 4.70 / 4.26 / 4.25 ms; **4.26 ms** |
| Inspect, 3876 × 2592 | 57.5 MiB | 76.7 MiB | 23.84 / 18.95 / 23.54 ms; **23.54 ms** | 14.48 / 14.16 / 15.54 ms; **14.48 ms** |
| Full, 7752 × 5184 | 230.0 MiB | 306.6 MiB | 88.26 / 84.28 / 85.11 ms; **85.11 ms** | 39.70 / 37.88 / 37.93 ms; **37.93 ms** |
| Full-session edit proxy, 2048 × 1370 | 16.1 MiB | 21.4 MiB | 8.56 / 8.58 / 8.46 ms; **8.56 ms** | 7.05 / 7.16 / 7.22 ms; **7.16 ms** |

On this bounded workload the proxy reduces the uncropped median by about 9.9×
and the cropped median by about 5.3× relative to full-sensor rendering. Three
samples are not a tail-latency estimate, so the report records a median and
maximum rather than labeling a nearest-rank value as p95.

The isolated process reached 713,001,072 bytes (680.0 MiB) peak physical
footprint in this tier order and reported 161,138,632 bytes (153.7 MiB) after
tier scopes released. The 1.21 GiB reusable ledger explains why resident memory
is not the safety metric. These are process-wide, order-dependent observations,
not a clean allocation delta for one renderer.

The [raw JSON](preview-scale-measurements-2026-09-14.json) contains every timing,
decode duration, retained payload, and Mach ledger sample. Its input SHA-256 is
`c71a348038f397743360ca41a2ac099f51b81c1dd81e319b39e39a05711f2fe7`.

## Environment and verification

- Mac16,7, arm64; macOS 15.7.9 (24G830); Apple Swift 6.1.2.
- Working tree based on `4e962c13552346f1b3a4b0bceeea92085b5cd0b0`.
- The pre-change baseline suite reported 626 tests in 365.278 s.
- After the implementation, 12 focused release tests passed in 8.620 s. They
  include the real-RAW full-preview gesture/refinement path, logical-versus-raster
  bitmap sizing, publication ordering/context rejection, manual-crop GPU use,
  and the opt-in scale probe.
- The final complete release suite reported 628 tests (616 passing records and
  12 opt-in skips) in 232.231 s.
- Strict formatting passed for every changed Swift source and test file.

The real-RAW integration test checks that the interaction backing stays at or
below 2048px, the logical canvas remains unchanged, and release replaces it with
the full backing and exact current parameters. Existing stale-source, selection,
geometry, and comparison generation checks remain active.

This does not measure native mouse input, screen presentation, energy, or
photographic acceptability of the temporary lower-resolution frame. The final
full-resolution frame remains the judgment surface, and the roadmap's packaged
photographic assessment is still open.

Reproduce the isolated probe from the repository root with the local RAF corpus
and normal macOS graphics access:

```sh
RUN_PREVIEW_SCALE_BENCHMARK=1 \
FSC_PREVIEW_SCALE_OUTPUT=/tmp/fsc-preview-scale.json \
CLANG_MODULE_CACHE_PATH=/tmp/fsc-preview-scale-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/fsc-preview-scale-swift \
swift test --disable-sandbox -c release \
  --package-path native/FilmScanEngine --jobs 2 --no-parallel \
  --filter PreviewScalePerformanceTests
```
