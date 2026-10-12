# CPU point correction and viewport overviews — September 28, 2026

This follow-up tests two exact-output opportunities after the
[September 27 implementation](implementation-2026-09-27.md). It preserves
processing profiles, tone versions, user preferences and current defaults.

## Changes

- `PhotographicProcessing` uses scalar BGR values in the initial photographic
  conversion instead of constructing/replacing a channel array for each pixel.
  Gray weights, channel evaluation order, transfer functions and rounding stay
  unchanged. The wheel-activity decision is prepared outside the output loop.
- `CPUPreviewPreparationCache` retains one raw overview at the requested bound,
  capped at 2,048px. It preserves the existing **full geometry → 2,048px →
  requested size** nearest-neighbor sampling, then corrects only those pixels.
  Analysis still comes from the immutable sensor; visible detail and complete
  refinement retain their existing sources. Bound/geometry changes rebuild the
  overview and update retained-byte accounting.

The scalar change primarily affects monochrome, slide and saved calibrated-color
rendering. Current C-41 and cyan-mask film bases use density-print rendering and
bypass that initial channel-array branch. Wheel preparation also applies to
density rendering; no general color or export speedup should be inferred.

## Research basis

Inspection of the saved ordinary-release binary confirmed a surviving heap
allocation in each calibrated-color/monochrome pixel conversion. The initial
normalized channel array was promoted to stack storage; claiming two heap
allocations per calibrated-color pixel would be incorrect. Wheel activity also
remained a per-pixel loop, while the mask array was already optimized away.

Apple's [Swift performance session](https://developer.apple.com/videos/play/wwdc2024/10217/)
and [Swift allocation guidance](https://www.swift.org/documentation/server/guides/allocations.html)
support checking release generated code rather than counting source-level
arrays. These sources explain the method, not the measured FSC improvement.
Assembly excerpts, binary hashes and detailed findings are retained in
`dist/performance-research-2026-09-28/cpu-research.md`.

## Measurement contract

Measurements use ordinary production release engine objects, frozen baseline
and candidate executables, and no concurrent native builds/tests. Hardware is
Apple M4 Pro (Mac16,7), 48 GiB RAM, macOS 15.7.9, Swift 6.1.2 and LibRaw 0.22.2.
Collection began with about 11 GiB free; a later verification check saw 61 GiB.
This study did not delete prior artifacts. Full image outputs are not saved by
the probe.

The full-source input is private `fuji400-fresh/DSCF2833.RAF`, decoded through
the camera-scan profile with `maxDimension: 100_000`: a 7,752×5,184 one-pass
preview source. Complete geometry/analysis are warmed outside timing. Each case
then renders exposure values `0.2`, `-0.2`, `0.4` EV with active version-4 tone
and protected-color controls. Cyan-mask/calibrated-color cases also use three
active grading wheels. Viewport requests include exact 1,200×800 detail at
`(256, 128)` plus a 1,024px overview; the first timed request includes overview
creation. Both returned rasters are hashed outside timing.

The expanded probe additionally hashes 72 untimed branch cases: small serial
and banded synthetic inputs, one/three source channels, versions 2–4,
calibrated color, monochrome, slide, enabled/disabled inversion, black-threshold
boundaries, curves and active wheels. This establishes old/new CPU agreement
independently of the GPU tolerance gate.

The saved initial baseline covers six cases. An expanded baseline adds the
calibrated-color case and branch oracles before the candidate; a frozen baseline
recheck uses the expanded harness. The original six workloads have identical
settings/sources in both harnesses. These are three observations per case per
process, not a population percentile estimate. Timers exclude RAW decoding,
first complete geometry warp, output hashing, bitmap packing, writing, app
publication and screen presentation. Viewport timings compare complete work for
that interactive request; they are not complete-frame render timings.

## Results

| Full-source workload | Initial baseline seconds | Candidate seconds | Baseline recheck seconds | Observed lower time |
|---|---:|---:|---:|---|
| C-41 density-print | 9.554 | 9.515 | 9.555 | Not established |
| Cyan-mask density-print, active wheels | 9.704 | 9.648 | 12.360 | Not established |
| Monochrome | 4.720 | 2.767 | 6.387 | 41–57% |
| Straightened viewport | 0.889 | 0.385 | 0.875 | 56–57% |
| Perspective viewport | 0.949 | 0.408 | 0.913 | 55–57% |
| Slide | 2.245 | 1.750 | 2.215 | 21–22% |
| Saved calibrated-color rendering, active wheels | 5.908 | 4.116 | 5.976 | 30–31% |

Values are medians of three exposure observations, not tail estimates. The
monochrome recheck varies substantially; the candidate remains below every
initial/recheck observation. The full-frame C-41 difference is under 0.5%, and
cyan-mask recheck variation prevents a general density/color speedup claim.
These bounded results do not establish a quieter-machine or population speedup.

The overview cache retains **12,920,832 fewer bytes (12.3 MiB)** for straightened
geometry and **12,478,464 fewer bytes (11.9 MiB)** for perspective in this run.
Those are raw cache-storage differences from identical geometry, not measured
process-footprint reductions. Source, corrected display buffers and complete
geometry still have their own storage.

Additional `proimage/DSCF5800.RAF` and `harmanphoenixii/DSCF3079.RAF` checks use
the same controls on 2,048px sources, filtering timed cases to monochrome,
calibrated color and the two viewports. Process order is baseline/candidate for
Pro Image and candidate/baseline for Phoenix. Their timing samples are retained
but **excluded from speedup claims**: Phoenix observations vary sharply, and a
process check after the proxy cohort showed substantial background activity.
The machine was not quiescent; other applications were left alone. No competing
builds/tests were started by this study. The full-source baseline bracketing
limits, but does not eliminate, uncertainty from changing background load.

All **45 timed full-frame/detail outputs**, **18 returned overviews**, and
**72 unique serial/banded branch oracles** match exact UInt16 pixel hashes
between baseline and candidate. Full-source recheck hashes also match. Parameters,
source dimensions, decoded-source hashes and input-file hashes match within each
comparison. These checks verify numerical equivalence on this cohort, not broad
photographic acceptance or three-pass export output.

## Verification

- Complete native release suite: **760 tests, 17 reported skipped checks, zero
  issues**, 640.314 seconds after a 397.35-second build. Its timings are not a
  performance comparison. The strengthened CPU viewport suite passed, including
  exact odd-dimension overviews, byte accounting and app gesture refinement.
- Ordinary production CPU/Metal comparator: **4,608/4,608 cases**, including
  4,164 GPU comparisons within 2/255 and 444 explicit CPU routes; zero failures.
- **Five freshly rendered preferred-look PNGs match exact ledger hashes**.
  Three RAWs were freshly decoded because historical cached scan buffers were
  unavailable. Historical median metadata remains intact and is used for the
  frozen settings; input/metadata/binary hashes are saved in
  `dist/performance-research-2026-09-28-preferences/input-manifest.json`.
  The preference ledger is unchanged. No reference fitting or reclassification
  is part of this check.
- Reusable probe: Python syntax/CLI/provenance guards and preflight passed. Its
  ordinary-release end-to-end proxy run completed for calibrated color; all 72
  branch hashes match the tested candidate. The production app build passed
  (38.32 seconds); the Lookbook build passed too.
- Strict recursive package Swift formatting, probe formatting and
  `git diff --check` pass.

Six-frame full-resolution photographic TIFF output, native pointer replay,
screen presentation, export throughput, process footprint/energy, packaged
release and MkDocs rendering were not rerun. Default RAW/standard-image export
regressions remain covered by the native suite. CPU preview-source agreement
does not establish three-pass export or Metal photographic agreement on unseen
frames. Additional repetitions on a quieter machine are needed before
generalizing the timing results.

## Further opportunities

These were follow-ups identified September 28. The [October 2 discovery](opportunities-2026-10-02.md#measured-and-rejected-straightforward-parallel-rgba8-packing)
subsequently tested and rejected a straightforward parallel RGBA8 candidate.
The [October 2 density-print lookup](implementation-2026-10-02.md) optimizes a
different branch from the calibrated-color lookup proposal below. Current
unmeasured questions are tracked in the [performance index](index.md#measurement-questions-still-open).

- Measure bounded parallelism for the currently serial initial pixel conversion
  after removing allocation overhead. Repeated band dispatch and contention may
  offset its benefit.
- For calibrated color only, an exact Double table over the existing 65,536-code
  UInt16 input domain may avoid repeated inversion/decode work. This needs
  exhaustive bit-pattern checks and preparation/amortization measurements; it
  must not substitute a quantized lookup for continuous weighted-gray input.
- Measure serial CPU `rgba8Data()` preview packing against the bounded packing
  pattern already used by export. Current correction timers omit publication
  packing, so they do not establish its cost.
- Measure standard-image writer overlap separately. Existing app-path export
  benchmarks use RAW, which deliberately stays one file at a time. September
  27's legacy neutral LZW TIFF packing was only 25.6 ms of a 6.966 s total;
  increasing export packing workers is not a supported priority.

The current nonisolated async export worker uses the executor behavior described
by [SE-0338](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0338-clarify-execution-non-actor-async.md).
Future toolchain adoption should retain its overlap regression gate when
considering [SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md).
No export concurrency or RAW quality change is part of this follow-up.

## Evidence

Fresh ignored artifacts live under
`dist/performance-research-2026-09-28/` (candidate provenance in
`dist/performance-research-2026-09-28/candidate-source-manifest.json`):
source/object fingerprints, engine snapshots, link commands, frozen executables,
`dist/performance-research-2026-09-28/CPUProbe.swift`, raw
timing/hash JSON, logs and research notes. Base HEAD is
`2b4da0930df3ccebc08c1e3197a8ec242df448ac`; pre-existing changes are preserved.
Use a fresh output after source/input changes and rebuild before linking probes.

The maintained
[`run-cpu-point-work-probe.py`](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/diagnostics/run-cpu-point-work-probe.py)
and [`CPUPointWorkProbe.swift`](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/diagnostics/CPUPointWorkProbe.swift)
preserve this workload with CLI/provenance guards. Reproduce one current-source
arm with a fresh output:

```sh
python3 native/diagnostics/run-cpu-point-work-probe.py \
  --raw sample-raw/fuji400-fresh/DSCF2833.RAF \
  --output dist/cpu-point-work-next --mode full
```

This builds and freezes one current production arm; a speed comparison still
requires a matched frozen baseline. Add `--preflight-only` for setup inspection
or `--cases blackAndWhite,calibrated-color` to limit timed cases. The 72 branch
oracles run independently of the timed-case filter.
