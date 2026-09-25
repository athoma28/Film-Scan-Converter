# C-41 preview output optimization — September 22, 2026

The requested **15% improvement is exceeded** for the full-resolution C-41
refinement selected by the [discovery run](c41-refinement-discovery-2026-09-22.md).
Across eight counterbalanced processes, median render-and-consume latency fell
from **107.92 to 46.22 ms: 57.2% less time, or 2.34× throughput** for this serial
workload. The synchronous render call alone fell from **91.34 to 21.38 ms**
(76.6% less time). Full-resolution consumed pixels match exactly.

These are measurements of one 40 MP photograph on an M4 Pro, with a separate
diagnostic bitmap draw. They do not measure native input-to-screen latency,
decode/export performance, or an app-wide percentage improvement.

## Implementation

`StillPreviewRenderer` now materializes complete large previews directly into
a buffer-backed Metal texture on unified-memory devices. Core Image completes
the render before a CGImage exposes the same buffer. Each output owns a separate
buffer through its CGDataProvider; releasing the source or rendering another
image cannot overwrite a retained preview. Padded `bytesPerRow` flows into the
app's existing corrected-raster cache accounting.

The path applies to complete rasters of at least 4,194,304 pixels, with integral
bounds no larger than 16,384 pixels per side. Scaled/viewport requests, smaller
images, non-unified devices, unsupported allocations and render failures use the
existing synchronous `createCGImage` path. Output remains RGBA8 sRGB with the
same orientation and full resolution. Shader and curve-LUT source are byte-for-
byte unchanged from the starting working tree; no precision, color defaults,
recipes, source tiers, scheduling, export or saved settings changed.

The exploratory Core Image task report showed roughly 24 ms of GPU work within
an approximately 92 ms render call, with four tiled passes. This motivated
changing output materialization. It does not establish an exact attribution of
all remaining time to readback. Identity-curve/shader specialization and a direct
bitmap destination were explored but did not establish the requested reliable
gain. Two exploratory shader outputs also failed exact hash equality; those
changes were discarded. Only the shared output-storage implementation remains.

## Controlled comparison

Collection used `main` at `fc63454e7d884fc0e9d272ff4f55ad93751227a2`, preserving
116 pre-existing dirty entries. The frozen baseline includes those existing
changes; it is not a clean-commit reconstruction. Its source hashes match the
discovery probe. The only production difference is `StillPreviewRenderer.swift`.
The diagnostic changes one descriptive note to say “synchronous raster
materialization”; timing logic and parameters are identical.

| Environment | Value |
|---|---|
| Hardware | Mac16,7, M4 Pro, 14 CPU cores, 20 GPU cores, 48 GiB RAM |
| OS / tools | macOS 15.7.9 (24G830), arm64, Swift 6.1.2, LibRaw 0.22.2 |
| Resources | About 82 GiB disk free; memory-pressure query reported 87% free |
| Power / thermal | Battery 29% → 28%; all eight processes recorded nominal thermal state |
| Build | Release production objects, normal macOS Metal access; CommandLineTools active |
| Cache | No cache purge; hashing warms filesystem pages; no cold-disk claim |

Input: `sample-raw/fuji400-fresh/DSCF2833.RAF`, SHA-256
`c71a348038f397743360ca41a2ac099f51b81c1dd81e319b39e39a05711f2fe7`.
The one-pass full preview is 7752×5184. Parameters are C-41 + Clean Invert,
photographic tone version 2, immutable 256px analysis, and manual crop
`(0.1, 0.1, 0.8, 0.8)` where applicable. This is not the three-pass export decode.

The final order was **baseline, candidate, candidate, baseline**, repeated twice.
Each process decoded once, warmed each case at EV 0, and timed EV −0.2, +0.2,
+0.4. No competing builds or benchmarks were launched during the comparison.
There are 12 warm samples per case per variant, 96 timed renders overall and
32 excluded warmups. A separate untimed memory/hash pass rendered every case/EV
twice: 192 additional renders. All 12 distinct case/EV hashes match across all
eight processes, with zero failed or skipped cases.

All entries below are median milliseconds, **baseline → candidate**. Component
medians need not sum to the median total.

| Case / raster | Render | Bitmap consumption | Total | Total reduction |
|---|---:|---:|---:|---:|
| Full refinement, 7752×5184 | **91.34 → 21.38** | 16.39 → 25.32 | **107.92 → 46.22** | **57.2%** |
| Cropped full, 6202×4148 | 50.56 → 19.12 | 11.38 → 17.07 | 61.99 → 36.63 | 40.9% |
| Editing proxy, 2048×1370 | 6.65 → 6.44 | 1.31 → 1.32 | 7.99 → 7.85 | 1.6% |
| Cropped proxy, 1640×1096 | 4.74 → 4.26 | 0.67 → 0.86 | 5.40 → 5.05 | 6.4% |

The proxy paths are unchanged controls; their variation is not attributed to
this optimization. Full-render per-process medians were 90.61/91.52/91.46/91.23
ms for baseline and 20.76/20.50/23.00/20.72 ms for candidate. Full total maxima
fell from 116.31 to 49.14 ms. Nearest-rank p95 equals the maximum for these
12-sample groups; it is not a stable population-tail estimate.

`renderReturn` includes graph setup, allocation, GPU completion and output
materialization. `consume` includes a new full-size RGBA8 CGContext, complete
draw and release. **The consumer is slower with shared output storage**, but the
combined saving remains 57.2%. The app does not necessarily perform this exact
additional draw, so this total is a conservative consumption guard rather than
a screen-presentation measurement.

## Memory and real app guard

Ranges across the four processes per variant, in MiB:

| Mach measurement | Baseline | Candidate |
|---|---:|---:|
| Process peak physical footprint | 809.05–811.66 | 768.47–773.88 |
| Physical footprint after local sources/renderers release | 142.42–196.38 | 241.61–245.03 |

The peak includes decode, all cases and the extra consumer surface. Shared
Core Image/Metal state remains alive after local release. Thus the measured
peak is lower while the post-release footprint is higher; this is not a general
memory-saving or leak claim. Resident and reusable bytes remain separate in
the raw reports. No energy or sustained pressure study was performed.

A separate one-repetition `AppPathPerformanceTests` run passed all three tests
in 42.354 s using the first ten local `aesthetic-test` RAFs. It verified:

- Two full retained previews and corrected rasters survived navigation; revisits
  produced two cache hits, zero full decodes and zero corrections.
- 1,000 settled viewport updates submitted no new correction or decode work.
- Saturated-cache switching submitted zero speculative lookahead requests.
- Every phase waited for AppModel release. Retained-navigation physical footprint
  fell from 1,038.82 MiB settled to 269.77 MiB after release. Final process
  footprint was 269.16 MiB, with a cumulative peak of 1,113.80 MiB.

The two-raster cache accounted for 1,455.11 MiB within its 3,072 MiB budget.
This is a lifecycle/counter guard, not an A/B app latency comparison or a
long-duration leak test. Its raw first/cached/uncached publication samples and
source tiers remain available, including intermediate-tier cache-depth samples.

## Correctness and exclusions

- Final focused release run reported **25 tests, zero issues**, including four
  new shared-output tests; the opt-in 640-entry editing replay was skipped.
  Coverage includes integer-offset crops, rotations/flips, channel and row order,
  padded rows, ownership after autorelease/source release, AppKit wrapping and a
  >4 MP production raster. Active tone/color/curve output matches the old writer
  exactly at full size. Existing retention, publication, invariant reuse and
  viewport suites passed.
- Final comparator passed **4,132/4,132 cases**: 3,796 GPU comparisons within
  2/255, 336 explicit CPU routes and zero render failures. These small synthetic
  cases complement, rather than replace, the new large-writer test and real-RAW
  exact A/B hashes.
- All **five preferred-look PNG hashes** match fresh production CPU renders of
  the three archived preference frames. The preference ledger is unchanged.
  These CPU checks are separate from GPU parity; no recipes were fitted.
- Release build and strict Swift formatting of the modified native source/test
  passed. The standalone audit retains its pre-existing formatting warnings;
  its only edit is the descriptive note. `git diff --check` passed.

Early test drafts incorrectly assumed Core Image retained fractional crop
extents; a fractional resampling fixture also differed between materializers.
That fixture is outside the optimized complete-raster contract and was removed;
scaled and viewport rendering retain their original path. One build was
interrupted by a concurrent formatting edit and was rerun successfully. The
exploratory failures and logs are preserved separately from final evidence.

The full native suite, broad photographic cohort, RAW determinism matrix,
export acceptance, packaged-app presentation, Intel/discrete GPU performance and
long-session memory/energy behavior were not rerun. This work makes no new
export, screen-latency or cross-hardware performance claim.

## Evidence and reproduction

All private inputs and generated images remain in ignored `sample-raw/` and
`dist/`. The local evidence root is `dist/c41-render-optimization-2026-09-22/`:

- [Final comparison manifest](../../dist/c41-render-optimization-2026-09-22/comparison/manifest.json)
  and [all samples, summaries, hashes and memory](../../dist/c41-render-optimization-2026-09-22/comparison/summary.json).
- [Candidate build/input/source/object provenance](../../dist/c41-render-optimization-2026-09-22/final-candidate/manifest.json),
  [baseline provenance](../../dist/c41-render-optimization-2026-09-22/baseline-provenance.json),
  [initial working-tree inventory](../../dist/c41-render-optimization-2026-09-22/initial-state.json)
  and [comparison script](../../dist/c41-render-optimization-2026-09-22/compare.py).
- [Final focused tests](../../dist/c41-render-optimization-2026-09-22/regression-final.log),
  [comparator](../../dist/c41-render-optimization-2026-09-22/comparator-final.log),
  [preference checks](../../dist/c41-render-optimization-2026-09-22/preferences-final/checks.json),
  [app-path report](../../dist/c41-render-optimization-2026-09-22/app-path.json)
  and [verification provenance](../../dist/c41-render-optimization-2026-09-22/verification-provenance.json).

To collect the current implementation, use a new output directory:

```sh
.venv/bin/python native/diagnostics/run-tone-control-audit.py \
  --timing-only --output dist/c41-shared-output-next
swift test -c release --package-path native/FilmScanEngine --no-parallel \
  --filter 'SharedPreviewBitmapTests|StillPreviewPerformanceTests|PreviewRetentionTests|PreviewPublicationTests|ViewportRenderingTests'
native/FilmScanEngine/.build/release/FilmScanPreviewComparator
```

Normal macOS graphics access is required. A new A/B study must preserve the
original binary/source provenance, record both variants and select a fresh
comparison directory; do not compare a new run to historical timings as if host
conditions were controlled. The frozen binaries, renderer snapshot and exact
commands for this completed comparison remain in the evidence root.
