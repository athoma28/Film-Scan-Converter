# RAW draft preview unpack optimization

The next measured target was compressed Fuji RAW unpack. The retained change
reduces median production draft-decode latency by **15.2–30.3%** across three
40 MP X-T5 photographs on the M4 Pro, meeting the requested 15% target for this
cohort. Every before/after RGB16 hash matches. This is an additional decode-stage
improvement; it must not be added to the earlier
[57.2% C-41 render-and-consume reduction](c41-shared-output-2026-09-22.md).

## Change and decision

The app requests a 640px camera-scan draft before its larger preview tiers. For
these files that produces 594×396 pixels, but the decoder still unpacks the
compressed sensor mosaic first. Baseline unpack medians were 258–266 ms out of
290–293 ms total decode time. Reducing the draft's demosaic resolution further
would leave this dominant cost intact.

The RAFs contain eleven independent compressed strips. The old shared
eight-worker ceiling required a second unpack wave. `RawTherapeePipeline.cpp`
now gives unpack its own ceiling of sixteen, bounded by CPU count and strip
count by default; these files use eleven workers. X-Trans demosaic remains
capped at eight. `FSC_UNPACK_WORKERS=1` and the RawPy-compatible path remain
serial. Strip arithmetic, dispatch order, locked input access, mosaic binning,
source tiers, correction parameters and pixel math are unchanged.

Wider unpack is conditional: a scoped atomic counter covers each camera-scan
decode, including demosaic, postprocessing and decoder cleanup. If another
camera-scan decode is active when unpack starts, its ceiling is eight, even
with a larger diagnostic override. Existing work is not resized mid-decode;
this is a conservative admission check, not a global CPU reservation. Early
returns and cancellation release the activity count through scope cleanup.

Two preceding experiments were rejected:

- Reordering the compressed strips by size with eight workers preserved pixels
  but did not improve the small trial (295.72 → 320.55 ms median).
- Unconditionally allowing eleven workers improved isolated drafts by
  16.2–20.3%, but uncached app switching regressed from 517.09 to 732.60 ms
  median, **41.7% higher**. That variant is not the retained implementation.
  The contention limit was added before the final measurements below.

## Final controlled decode comparison

Source started at `fc63454e7d884fc0e9d272ff4f55ad93751227a2` with 118 existing
dirty entries, including the preceding renderer optimization. Frozen release
probes link the production `RawImageDecoder` and native shim. All source hashes
match between the two probes except `RawTherapeePipeline.cpp`; the probe itself
is identical. The baseline uses eight unpack workers, the candidate eleven.

Hardware: Mac16,7, Apple M4 Pro (10 performance + 4 efficiency CPU cores),
48 GiB RAM; macOS 15.7.9, Swift 6.1.2 and LibRaw 0.22.2. Initial free disk was
80.98 GiB. Input SHA-256 values, source/object/binary hashes and tool output are
saved with the evidence. RAW headers identify all three files as X-T5.

For each draft, eight fresh processes ran in ABBA ABBA order. Each process had
one excluded warmup followed by five timed decodes: **20 timed samples per
variant per file**. A separate ABBA sequence measured inspect/full-sensor tiers
on DSCF2833 with six timed samples per variant per tier. There were 176 decodes
in total, including 32 excluded warmups, and no failures or skipped cases.

The timer surrounds the synchronous production decode, including resource
cleanup inside that call. Output hashing occurs after timing. No filesystem
caches were purged; hashing inputs warms their pages. Runs were sequential,
without concurrent builds or other benchmarks. All recorded thermal states
were nominal. At both ends of this final decode run, `pmset` reported AC power
with the battery at 13% and discharging; power was recorded, not controlled.

| Draft input under `sample-raw/` | Baseline median ms | Final median ms | Lower latency | Baseline / final p95 ms | Baseline / final maximum ms |
|---|---:|---:|---:|---:|---:|
| `fuji400-fresh/DSCF2833.RAF` | 289.54 | 201.71 | **30.3%** | 304.80 / 247.77 | 376.44 / 255.76 |
| `aesthetic-test/DSCF3233.RAF` | 292.68 | 232.02 | **20.7%** | 305.37 / 250.09 | 309.11 / 259.94 |
| `harmanphoenixii/DSCF3079.RAF` | 293.06 | 248.65 | **15.2%** | 296.86 / 261.28 | 297.87 / 264.23 |

Final unpack medians were 167.93, 200.43 and 219.42 ms, respectively. These are
medians of individual stages; subtracting them from total medians does not
produce an independently timed stage. The last file only narrowly exceeds
the target. Process medians vary, especially for DSCF2833 (candidate process
medians 180.71–240.29 ms); the percentage is a measured cohort result, not a
guaranteed minimum for every decode.

| DSCF2833 control tier | Output pixels | Baseline median ms | Final median ms | Lower latency | Baseline / final p95 and maximum ms |
|---|---|---:|---:|---:|---:|
| Requested 4000px inspect | 3876×2592 | 1685.47 | 1525.51 | 9.5% | 1773.20 / 1566.20 |
| Full-sensor one-pass preview | 7752×5184 | 3553.72 | 3346.54 | 5.8% | 3655.33 / 3470.84 |

All 176 output hashes agree with their matching baseline case, including warmup
decodes. The larger tiers remain dominated by subsequent processing and do not
meet the 15% target. Nearest-rank p95 is descriptive; with six samples it equals
the maximum. This is neither a three-pass export benchmark nor screen latency.

## App contention and memory guard

The final release test executable ran the unchanged `AppPathPerformanceTests`
four times in eight/default/default/eight order, three repetitions per process.
`FSC_UNPACK_WORKERS=8` reproduces the old dispatch in the same binary. The default
arm permits eleven workers when alone and caps newly starting concurrent
unpack at eight. All four runs passed all three tests. The ten-file cohort,
input hashes, harness and executable were unchanged between arms.

| Existing app-model wait metric | Eight workers median ms | Final default median ms | Eight / default p95 and maximum ms |
|---|---:|---:|---:|
| First corrected preview | 1108.38 | 373.05 | 1456.89 / 760.23 |
| Cached switch | 22.48 | 24.13 | 25.92 / 24.83 |
| Uncached switch | 962.91 | 679.10 | 1616.87 / 853.83 |
| Rapid selection drain | 1099.29 | 473.91 | 1401.56 / 733.94 |

The earlier uncached-switch regression did not recur. Cached-switch median rose
1.65 ms, below the harness's 5 ms polling interval. The other distributions
are broad: the wait additionally requires `!isLoading && !isRendering`, so it
can observe a later settled state after initial publication. These six-sample
summaries support the workflow guard, not a stable app-wide percentage gain or
input-to-screen claim. The host reported battery power, 15% → 13%, during this
app cohort; it does not record thermal state. Do not compare its absolute
latencies with the earlier one-repetition renderer guard or other cohorts.

Each process also verified six retained cache hits, **zero new full decodes or
corrections** during retained navigation, 1,000 viewport updates without new
decode/correction work, and zero speculative requests for all three saturated
cache switches. Each phase waited for model release.

| Process memory, MiB (two processes per arm) | Eight workers | Final default |
|---|---:|---:|
| Cumulative peak physical footprint | 1119.00–1121.11 | 1112.33–1127.19 |
| Physical footprint after model release | 269.05–276.47 | 267.69–277.32 |
| Reusable allocator bytes after release | 2645.88–2647.42 | 2659.20–2684.94 |

Reusable bytes are not physical footprint. These short runs establish neither
a memory saving nor a long-session leak/energy result.

## Correctness and remaining limits

- The final release source passed **13 camera-scan identity and scheduler tests**,
  including real cancellation/recovery and scheduled/direct final-quality
  stage-hash parity. A new test compares the 640px draft with one, eight and
  eleven actual unpack workers: complete RGB16 pixels and all five stage
  digests match the serial oracle. Existing full-resolution fixture and serial
  unpack/demosaic oracles also pass.
- Before adding the contention cap, the same wider strip dispatch passed the
  broader **38-test** RAW/identity/scheduler run, including photographic and
  RawPy compatibility checks; the opt-in bound sweep was skipped. That broader
  run is recorded separately and is not presented as a rerun on final source.
- The final CPU/Metal comparator passes **4,132/4,132 cases**: 3,796 GPU
  comparisons within 2/255, 336 explicit CPU routes, zero render failures.
- All **five fresh preferred-look CPU PNGs** match the unchanged preference
  ledger, using archived 900px scan buffers and frozen settings. These checks
  are separate from the real-RAW stage identities and GPU comparator.
- Release builds, strict formatting of the added Swift test and
  `git diff --check` pass. Source fingerprints preserve all unrelated initial
  changes, the prior shared-output optimization, defaults and reference files.

The complete native suite, three-pass export/writer acceptance, other sensor
families and CPU counts, packaged-app presentation, sustained navigation under
memory pressure and controlled power/energy behavior were not measured here.
Early exploratory build/launcher failures are retained in logs and excluded
from timing and pass counts. No preset fitting or reference regeneration was
performed. The next broad RAW optimization would need to address demosaic for
larger tiers; this report does not establish a safe implementation for it.

## Evidence and reproduction

The ignored local root is `dist/raw-preview-optimization-2026-09-22/`. Private
inputs and generated images remain in `sample-raw/` and `dist/`.

- [Initial tree](../../dist/raw-preview-optimization-2026-09-22/initial-state.json),
  [environment](../../dist/raw-preview-optimization-2026-09-22/environment.json),
  [baseline build](../../dist/raw-preview-optimization-2026-09-22/baseline/manifest.json)
  and [final build](../../dist/raw-preview-optimization-2026-09-22/bounded-candidate/manifest.json).
- [Final RAW manifest](../../dist/raw-preview-optimization-2026-09-22/bounded-comparison/manifest.json)
  and [every timed sample and summary](../../dist/raw-preview-optimization-2026-09-22/bounded-comparison/summary.json).
  Individual reports also retain warmups, all stage timings and thermal states.
- [Final app manifest](../../dist/raw-preview-optimization-2026-09-22/bounded-app-comparison/manifest.json)
  and [samples and memory](../../dist/raw-preview-optimization-2026-09-22/bounded-app-comparison/summary.json);
  [rejected unrestricted app comparison](../../dist/raw-preview-optimization-2026-09-22/app-comparison/summary.json).
- [Final 13 tests](../../dist/raw-preview-optimization-2026-09-22/bounded-regressions.log),
  [earlier broader tests](../../dist/raw-preview-optimization-2026-09-22/raw-regressions-final.log),
  [comparator](../../dist/raw-preview-optimization-2026-09-22/comparator-final.log),
  [preferred-look checks](../../dist/raw-preview-optimization-2026-09-22/preferences-final/checks.json)
  and [final provenance](../../dist/raw-preview-optimization-2026-09-22/final-verification.json).

The saved [RAW comparison script](../../dist/raw-preview-optimization-2026-09-22/compare-bounded-raw.py)
and [app comparison script](../../dist/raw-preview-optimization-2026-09-22/compare-bounded-app.py)
record their exact commands. Use a fresh output path for a repeat; neither
overwrites completed evidence. Focused correctness can be rerun with:

```sh
swift test --disable-sandbox -c release --package-path native/FilmScanEngine \
  --no-parallel --filter 'CameraScanByteIdentityTests|RawDecodeSchedulerTests'
native/FilmScanEngine/.build/release/FilmScanPreviewComparator
```
