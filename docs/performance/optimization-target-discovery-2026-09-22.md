# Optimization target discovery — September 22, 2026

**Dated source-only discovery.** Its proposed Stage 2 measurement was completed
in the [refinement study](c41-refinement-discovery-2026-09-22.md), followed by
the [shared-output implementation](c41-shared-output-2026-09-22.md). References
below to “this checkout,” the next target, disk space, and work left to do
describe the September 22 collection state. Use
[development status](../development/native-macos.md) for current verification.

Completed **Stage 0** of the [collection runbook](../development/data-collection-optimization-target-discovery.md).
The first target to investigate is **full-resolution C-41 refinement after an
edit**, separating rendering from output consumption before changing either.
The most relevant existing measurement records **133.20 ms median**, while its
2048px editing proxy records **9.27 ms**. All 99 source hashes in that report's
manifest, its saved probe executable, and its timing input match this checkout.
These are existing September 22 samples, not a new benchmark or measured
mouse-to-screen latency. No optimization benefit has yet been established.

Stop here for this pass: existing evidence identifies a useful target, and the
data volume is **98% full with 11.53 GiB available**. A synthetic benchmark would
not answer the remaining real-RAW rendering question. No builds, tests, RAW
decodes, exports, galleries, or processing/default changes were made. The next
bounded measurement is Stage 2, specified below; larger stages remain deferred.

## Collection and provenance

The local collection was made September 22 PDT / September 23 UTC, on `main` at
`fc63454e7d884fc0e9d272ff4f55ad93751227a2`, with **113 pre-existing dirty entries**.
The manifest captures 423 source/document/test files before this report was added.
Existing working-tree edits and historical evidence are preserved.

| Environment / resource | Observed value |
|---|---|
| Hardware | Mac16,7, Apple M4 Pro, 14 CPU cores (10 performance / 4 efficiency), 48 GiB RAM |
| OS / toolchain | macOS 15.7.9 (24G830), arm64; Swift 6.1.2; LibRaw 0.22.2 |
| Xcode | Active developer directory is CommandLineTools; `xcodebuild -version` unavailable |
| Graphics | System profiler reports 20-core M4 Pro GPU with Metal support; rendering access was not exercised |
| Memory | `memory_pressure -Q`: 53% system-wide memory free; `vm_stat`: 1.06 GiB free pages, 18.0 GiB occupied by compressor. These are distinct system metrics, not app footprint or an allocatable-memory guarantee. |
| Disk | 12,376,035,328 bytes available on the shared repository/temporary data volume at collection |
| Power / thermal | `pmset` reported AC Power and battery 55% discharging; retained verbatim. Thermal queries returned unavailable, so thermal headroom is unknown. |
| Inputs | 72 RAF paths available; one selected RAW was hashed, none decoded |
| Existing builds | Five release executables/test bundles fingerprinted; timestamps alone were not treated as source compatibility proof |

`sysctl` hardware access failed in the sandbox; filtered `system_profiler`
hardware data supplied the model/core details without requiring elevated access.
No caches were purged. Reading the selected RAW for hashing can warm filesystem
pages; no future run should be called physically cold on that basis.

Compact collection artifacts are under ignored
[`dist/optimization-target-discovery-2026-09-22/`](../../dist/optimization-target-discovery-2026-09-22/manifest.json),
budgeted to **1 MiB**, with no images:

- [Environment, dirty state, source/binary fingerprints, selected input and next workload](../../dist/optimization-target-discovery-2026-09-22/manifest.json)
- [Metric inventory with exact switches, inputs, outputs, assertions and limitations](../../dist/optimization-target-discovery-2026-09-22/metric-inventory.json)
- [Index of existing compact reports](../../dist/optimization-target-discovery-2026-09-22/report-index.json)
- [Historical raw samples and recomputed summaries](../../dist/optimization-target-discovery-2026-09-22/historical-observations.json)
- [Source-manifest comparisons](../../dist/optimization-target-discovery-2026-09-22/provenance-comparison.json)

## What is actually measured or asserted

Commands and input contracts remain in [tests/README.md](../../tests/README.md)
and [native/README.md](../../native/README.md). Each opt-in switch enables only
its named workload. Use one exact filter, release mode and serial execution;
create an output variable's parent directory first.

| Harness / signal | Classification | Input and retained output | Actual guard; timing limits |
|---|---|---|---|
| Default processing, RAW, publication, retention and scheduler suites | Default test assertion | Committed fixtures; local RAW cases require their private files; test records | Pixel/hash, latest-value publication, work reuse, cache accounting and cancellation contracts. No universal app latency or physical-footprint gate. |
| `productionRendererBurstBenchmark`; `RUN_PERFORMANCE_TESTS` | Opt-in test assertion | Random 1080×720 source and 500 settings; stdout summaries | Zero render failures and indexed p95 ≤33 ms. No raw sample output or explicit bitmap consumption in the timer. |
| `CPUPipelineBenchmarkTests`; `RUN_PERFORMANCE_TESTS` | Opt-in report-only timing | Synthetic CPU/packing cases; DNG case writes a temporary image; stdout summaries | Most cases reject empty/nil output; DNG uses `try?` and does not assert writer success. No speed threshold. Select one function, not the whole suite. |
| `PreviewAnalysisPerformanceTests`; `RUN_PREVIEW_ANALYSIS_BENCHMARKS` + `PREVIEW_ANALYSIS_CASE` | Opt-in report-only timing | Four deterministic case choices; stdout JSON with five samples and Mach footprint | Each result equals warmup, Mach query succeeds; no speed gate. Default `PreviewAnalysisTests` separately pins historical analysis/output hashes. |
| `NaturalMonochromeLookupTests/benchmark`; `RUN_NATURAL_BW_LOOKUP_BENCHMARK` | Opt-in report-only timing | 2048×1024 legacy B&W; stdout raw samples/counters | Exact ordinary/cold/warm output equality; no speed threshold. Version 2 is deliberately ineligible for this lookup. |
| `benchmarkEditingWithPersistence`; `RUN_EDIT_REPLAY_BENCHMARK` | Opt-in report-only timing | Committed PNG, temporary 640-entry store, 60 setters; stdout `EDIT_REPLAY` | Publishes during drag, latest parameters and saved exposure agree; no latency threshold or native input measurement. |
| `PerformanceFollowupBenchmarks`; `RUN_WORK_REUSE_BENCHMARK` | Opt-in report-only timing | Synthetic CPU case plus DSCF2833; optional `WORK_REUSE_BENCHMARK_OUTPUT` JSON | Nonempty dimensions/statistics and successful renders; three alternating warm samples; no timing or physical-memory gate. |
| `AppPathPerformanceTests`; `RUN_APP_PATH_PERFORMANCE_TESTS` | Opt-in report-only timing | ≥4 RAFs, first ten lexical paths; repetitions default 3; optional `APP_PATH_BENCHMARK_OUTPUT` JSON | Retained revisits/1,000 viewport updates add no full decode or correction; expected cache hits and model release. Saturated speculative counts are reported. 5 ms polling, no speed/footprint threshold. |
| `AppPathExportPerformanceTests`; `RUN_APP_PATH_EXPORT_PERFORMANCE_TESTS` | Opt-in report-only timing | ≥4 RAFs expanded to ten TIFF jobs and cancellation; optional `APP_PATH_EXPORT_BENCHMARK_OUTPUT` JSON | Completion/progress, no errors, queue cancellation and artifact cleanup; no latency/peak-footprint threshold. |
| `PreviewScalePerformanceTests`; `RUN_PREVIEW_SCALE_BENCHMARK` | Opt-in report-only timing | DSCF2833, draft/inspect/full/proxy; optional `FSC_PREVIEW_SCALE_OUTPUT` JSON | Renderer/crop support and consumed statistics required. Three warm samples per arm; no speed threshold. Uses calibrated-color inversion, unlike the C-41 tone audit. |
| `cameraScanPreviewBoundLatencySweep`; `FSC_PREVIEW_BOUND_SWEEP` | Opt-in report-only timing | Representative RAF, six bounds × three decodes; stdout medians/last substages | Dimensions and preview-bound flag asserted. Skips without corpus even when enabled; individual wall samples not emitted. |
| `RepresentativeRollWorkflowTests`; `RUN_REPRESENTATIVE_ROLL_TESTS` | Opt-in test assertion | Fuji DSCF2833/2851/2856; temporary settings/TIFFs removed | Transfer, exceptions, preview/export changes, re-export reuse, reader correctness, persistence and input hashes; not a speed gate. |
| `FilmScanExportBenchmark` | Standalone diagnostic | Explicit RAF, formats/repetitions; requested JSON; each image hashed/deleted | Removal checked; determinism records eight boundary agreements. LZW TIFF differs from app's default uncompressed TIFF; engine path omits app queue/classification. |
| `FilmScanRawBenchmark`, `FilmScanAdjustmentBenchmark` | Standalone diagnostics | All RAFs under supplied root / seeded 1080×720 synthetic source | Decode/render failures fail; no speed threshold. RAW tool uses compatibility profile; adjustment tool prints aggregates without a bitmap consumer. |
| Tone audit and color-study runner | Standalone diagnostics | Fresh ignored output; exact private inputs/provenance | Tone CLI also builds/renders ramps and photographs; no timing-only selector. Full color workflow still has documented recipe/schema integration gaps. |
| Presented-frame latency, sustained cache/eviction curves, energy | Proposed signals not yet collected | No complete current report found | Existing `RenderStats`/signposts describe model publication. Energy and sustained-capacity studies require separate controlled workloads. |

CI runs ordinary tests with coverage and reports/uploads coverage; it does not
set these benchmark switches or provide the private RAW corpus. Suite duration
and coverage are test-health signals, not app latency measurements. No new test
pass, skip, failure, or coverage result is claimed in this collection.

Two harness details matter before comparisons: burst/CPU percentile indexing is
not the runbook's nearest-rank convention, and several synthetic tools discard
raw samples. Neither should replace the consumed-output, recorded-sample cohort
below simply because its command is cheaper.

## Ranked targets

### 1. Full-resolution C-41 refinement and unnecessary final-render work

**Decision: measure again before optimizing.** This has the strongest relevant
provenance. The [saved tone timing JSON](../../dist/tone-controls-fixed-final-2026-09-22/performance.json)
matches the current engine/harness source and its saved binary, although it was
not rerun in this collection. Source is the 7752×5184 one-pass RAW preview of
`fuji400-fresh/DSCF2833.RAF`, C-41 + Clean Invert, tone schema 2, with immutable
256px analysis. EV 0 warms each case; timed EVs are −0.2, +0.2 and +0.4.

| Warm direct-render case | Raw samples (ms) | Median (ms) | Max / nearest-rank p95 (ms) |
|---|---|---:|---:|
| 2048×1370 uncropped proxy | 10.176583, 8.171250, 9.266250 | 9.266250 | 10.176583 |
| Full uncropped refinement | 133.199750, 133.287584, 130.847583 | **133.199750** | 133.287584 |
| 2048×1370 cropped proxy | 5.395416, 5.791000, 5.828375 | 5.791000 | 5.828375 |
| Full cropped refinement | 73.471584, 65.067000, 66.883250 | 66.883250 | 73.471584 |

The crop is `(0.1, 0.1, 0.8, 0.8)`. Every timer includes rendering and a full
RGBA8 Core Graphics draw. It excludes RAW decode, renderer construction, model
queueing, event dispatch and presentation. Three samples do not estimate a
population tail. The implementation note's 133.29 ms “median” is the maximum
sample rounded; raw JSON and recomputation agree on **133.20 ms**. Historical
files were left intact.

Potential impact is waiting for an exact complete raster after editing. The
remaining cost could include shader work, rasterization/readback, allocation and
the consumer draw; this report cannot assign it to one operator. The direct
harness records no submitted/dropped/reused/cancelled model counters or Mach
footprint. Energy is unmeasured. One RGB16 source is about 230 MiB, retained RGBA16
backing 306.6 MiB, and a full RGBA8 consumer surface 153.3 MiB; these are nominal
payloads, **not** observed peak live memory or the complete Float32 working set.

The proxy's lower timing is not permission to substitute it for final detail.
Before optimizing shader arithmetic, determine whether repeated final requests
or duplicate materialization can be avoided. Preserve final current-parameter
publication, full-size detail, stale-generation rejection, CPU/Metal ≤2/255,
tone-version compatibility and the five preference checkpoints. Measurement
effort is small; processing changes carry higher photographic risk. No speedup,
memory saving or repeated-work defect is established yet.

### 2. First and uncached corrected publication

**Decision: measure again after target 1.** The September 19
[app-path report](retained-preview-measurements-2026-09-19.json) used release
`c4ad5ba` plus the recorded local changes, M4 Pro/48 GiB, macOS 15.7.9,
Swift 6.1.2 and LibRaw 0.22.2. Its first ten lexical RAF paths still match the
current directory inventory, but their hashes were not rechecked in this pass.
The harness hash matches; **17 of 93 recorded production files differ** today.

First-publication samples were **580.639166, 628.704958, 360.586917 ms** (median
580.64, max/p95 628.70). Uncached-switch samples were **415.805459, 366.533250,
369.491208 ms** (median 369.49, max/p95 415.81). Filesystem cache was not forced
cold. Model publication is the timing boundary; source tiers and scheduler work
must be recorded before attributing a delay to decode or correction.

Retained navigation already had six cache hits, zero full decodes/corrections,
and about 6.50 ms publication near the 5 ms polling floor. Saturated-cache
speculative submissions were **0, 0, 0** after the repair. Do not re-propose that
already completed optimization. The retained pair used 1,526,127,616 logical
bytes, 1,165,496,376 bytes settled physical footprint, and 119,394,120 bytes
physical footprint after release; these are different quantities, with no proven
memory reduction. Depths 2/8/32 populated only 2/4/4 initial-lookahead sessions.

Reuse `AppPathPerformanceTests` and the existing preparation/queue/render
statistics plus per-file signposts to locate avoidable work. Guard priority,
cancellation, bounded concurrency, retained-pixel correctness and memory-pressure
behavior. A current-source rerun costs multiple RAW loads and roughly GiB-scale
live memory without disk images. Implementation effort/risk is medium because
scheduling changes can trade foreground latency for useful speculation. No
current-source gain or sustained-roll capacity result is established.

### 3. Three-pass export decode/demosaic cost

**Decision: defer; refresh one-file stage timing before considering decoder work.**
The September 16 [determinism report](raw-work-reuse-determinism-2026-09-16.json),
based on `4e962c1` plus its recorded local work, uses the same Fuji frame,
40.186368 MP, LibRaw 0.22.2, eight unpack/demosaic workers and LZW TIFF.
Its environment fingerprint is less complete than the newer tone collection;
do not substitute today's environment as historical metadata.

First-run demosaic was **4.523502 s**; four warm samples were **4.410922,
4.343709, 4.375448, 4.370232 s** (median 4.372840, max/p95 4.410922).
Total decode includes diagnostic hashes, so its 5.716728 s five-sample median
is not plain app export decode time. All eight boundaries agreed across five
repetitions and across serial/parallel variants. Each 174,847,758-byte TIFF was
removed. Parallel process peak was 701,384,120 bytes; after-release physical
samples were 67,618,592 / 15,894,424 / 17,467,456 / 17,680,520 / 18,106,576 bytes.

This suggests more opportunity in decode than an already roughly 15 ms packing
stage, but newer processing and format choices can change the complete balance.
Selected-file settings-only export already retains its three-pass decode;
standalone engine measurements do not exercise that reuse. Use one explicit
frame and `--formats=tiff` for the next plain stage report, retaining first-run
and warm samples separately. Keep exact stage/pixel hashes, serial oracle,
writer-input/output hashes, cleanup and cancellation guards. Decoder changes
have high correctness risk; no further speedup is estimated. Do not enable
overlapping-tile OpenMP or weaken the final-quality decode to chase this number.

## Selected next measurement and stopping rule

Select **Stage 2: one-frame C-41 full refinement**, using
`sample-raw/fuji400-fresh/DSCF2833.RAF`, SHA-256
`c71a348038f397743360ca41a2ac099f51b81c1dd81e319b39e39a05711f2fe7`.
Keep the version, recipe, one-pass source, analysis, EV sequence and full bitmap
consumer from target 1 fixed. Retain the proxy as a control, without treating
its lower resolution as an equivalent final image.

The smallest useful harness follow-up is a **timing-only selector in the existing
tone diagnostic**, retaining source/input/binary provenance and raw samples.
Its current CLI unconditionally builds and runs ramps and six-frame photograph
sweeps. `PreviewScalePerformanceTests` can instead gain an explicitly labeled
C-41 case, but its current calibrated-color inversion, crop and bounded statistics
consumer do not reproduce the tone cohort. Neither change was needed to finish
this source-only inventory, and neither was made here.

That bounded run should split render-return time from forced output consumption
and sample physical/peak footprint separately from logical/reusable bytes. Check
fresh disk/memory/thermal conditions and graphics access first; reuse a release
build only after verifying compatibility. Allow no disk image outputs and at
most 1 MiB of new JSON/logs. Stop if this identifies the dominant stage. Only
then correlate real AppModel requests/publications, and, if needed, a Stage 3
gesture/presentation trace. Do not interpret GPU submission as frame delivery.

Full color fitting remains deferred until recipe/parser migration is resolved;
the later tone fix does not establish complete study compatibility. Sustained
roll eviction/reloads and energy/thermal studies are also deferred. Historical
export timings collected alongside a build are excluded from isolated speed
claims. No reference fixtures or preferred looks need changing for discovery.
