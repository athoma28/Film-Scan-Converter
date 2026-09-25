# C-41 refinement target discovery — September 22, 2026

**Dated measurement.** The render-path target selected here was followed by the
[shared-output implementation](c41-shared-output-2026-09-22.md). The timings
below describe the pre-change cohort; they are not the current render latency.
See [development status](../development/native-macos.md) for current evidence.

Completed the bounded **Stage 2** follow-up selected by the
[source-only discovery pass](optimization-target-discovery-2026-09-22.md) and
[collection runbook](../development/data-collection-optimization-target-discovery.md).
The next optimization target is the **production full-resolution render path**:
two sequential runs measured **88.98 / 92.69 ms median** inside the render call,
accounting for **83–86%** of the uncropped render-and-consume samples. The extra
diagnostic bitmap draw costs about **16 ms**. This locates the dominant measured
stage; it does not isolate shader arithmetic, establish redundant app work, or
measure input-to-screen latency.

No production code, processing defaults, saved settings, fixtures, or preferred
looks changed. There is **no measured optimization speedup**. The earlier
133.20 ms total and this collection have different harness/host conditions,
despite matching production sources and RAW input.

## Collection and reproducibility

Collection occurred September 22 PDT / September 23 UTC on `main` at
`fc63454e7d884fc0e9d272ff4f55ad93751227a2`, preserving **114 pre-existing dirty
entries**. Both finalized runs have identical fingerprints for all 99 recorded
source/package/harness files, linked objects, input, and probe executable. Against
the earlier tone report, all 97 production/package files match; only the two
diagnostic files changed.

| Environment | Recorded value |
|---|---|
| Hardware | Mac16,7, M4 Pro, 14 CPU cores, 20 GPU cores, 48 GiB RAM |
| OS / tools | macOS 15.7.9 (24G830), arm64, Swift 6.1.2, LibRaw 0.22.2 |
| Xcode | CommandLineTools active; full `xcodebuild -version` unavailable |
| Graphics | Metal available and exercised with normal macOS graphics access |
| Resources | Approximately 82.3 GiB free before each finalized run; `memory_pressure -Q` reported 87% system-wide free memory |
| Power / thermal | Battery power, 35%; Swift thermal state nominal before/after both runs and after every case. `pmset` thermal query unavailable. Energy was not measured. |
| Cache conditions | No caches purged. Input hashing warms filesystem pages. Each process decodes once; its first decode and EV-0 warmups are recorded separately. No physically cold-disk claim. |

The selected RAW is `sample-raw/fuji400-fresh/DSCF2833.RAF`, SHA-256
`c71a348038f397743360ca41a2ac099f51b81c1dd81e319b39e39a05711f2fe7`.
The production camera-scan decoder uses `maxDimension: 100_000`, yielding the
7752×5184 **one-pass preview**, not the separate three-pass export decode.
Settings are explicit C-41 + Clean Invert, photographic tone version 2, with
immutable 256px analysis and its measured medians. Each case constructs a
renderer, warms EV 0, then times EV −0.2, +0.2, +0.4. The manual crop is
`(0.1, 0.1, 0.8, 0.8)`.

Reproduce one process with a fresh output directory:

```sh
.venv/bin/python native/diagnostics/run-tone-control-audit.py \
  --timing-only --output dist/c41-refinement-next
```

The runner incrementally builds the production objects, compiles the probe,
requires Metal, records source/input/object/binary hashes and environment, and
checks content stability through completion. The timing-only mode requires just
the selected RAW; it does not require archived color-study scans. It creates no
image files, exports, ramps, galleries, or model preferences. Its generated
2,746,568-byte executable lives in the ignored package build directory; JSON and
logs are budgeted below 1 MiB. Reusing a populated output directory or writing
outside ignored `dist/` is rejected.

Evidence:

- Run A: [manifest](../../dist/optimization-target-discovery-2026-09-22-stage2-final/manifest.json),
  [raw timings, memory, hashes](../../dist/optimization-target-discovery-2026-09-22-stage2-final/performance.json),
  [exact parameters](../../dist/optimization-target-discovery-2026-09-22-stage2-final/parameters.json).
- Run B: [manifest](../../dist/optimization-target-discovery-2026-09-22-stage2-repeat/manifest.json),
  [raw timings, memory, hashes](../../dist/optimization-target-discovery-2026-09-22-stage2-repeat/performance.json).
- [Collection validation and comparison](../../dist/optimization-target-discovery-2026-09-22-stage2-final/collection-validation.json)
  and [fresh comparator log](../../dist/optimization-target-discovery-2026-09-22-stage2-final/comparator.log).

An initial exploratory run remains in
`dist/optimization-target-discovery-2026-09-22-stage2/`; it completed with zero
skips/failures and showed the same dominant stage. The harness subsequently added
explicit buffer-lifetime protection around memory checkpoints. That earlier run
has a different harness/executable fingerprint and is excluded from the paired
results below. No historical artifact was overwritten.

## Timings

All values are milliseconds; cells show **run A / run B**. These are three warm
samples per case per process. Nearest-rank p95 equals the maximum of three and
is not a stable population-tail estimate. Phase medians need not add to the
median total because their ordering can differ.

| Case / output raster | Render median | Consumer median | Total median | Total max / p95 |
|---|---:|---:|---:|---:|
| Uncropped editing proxy, 2048×1370 | 6.10 / 7.31 | 1.00 / 1.24 | 7.12 / 8.55 | 7.20 / 9.97 |
| Full refinement, 7752×5184 | **88.98 / 92.69** | 16.21 / 16.08 | **105.19 / 109.33** | 105.82 / 110.27 |
| Cropped proxy, 1640×1096 | 4.63 / 4.68 | 0.75 / 0.66 | 5.39 / 5.33 | 5.57 / 5.47 |
| Cropped full refinement, 6202×4148 | 49.47 / 51.15 | 11.13 / 11.03 | 61.58 / 62.18 | 64.52 / 64.04 |

The uncropped full-render raw samples are **89.834209, 82.682167, 88.980250**
and **92.691000, 94.332833, 86.082667**. Corresponding consumer samples are
**15.990625, 16.631875, 16.208542** and **16.642958, 15.936334, 16.081958**.
Every case's individual samples and EV-0 warmup remain in the JSON.

`renderReturn` starts before `StillPreviewRenderer.render` and ends when its
CGImage returns. The implementation uses synchronous
`CIContext.createCGImage(... deferred: false)`: graph setup/analysis, GPU work,
synchronization, allocation and materialization may all contribute. This is
**not shader-only GPU time**. `consume` measures a newly allocated full-size
RGBA8 CGContext, complete draw, and context release. Memory queries and hashing
run later in a separate untimed pass, avoiding that instrumentation in timings.

The app publishes the render result through its retained-preview path; the
diagnostic's extra CGContext is not evidence that the app performs this same
additional full-size draw. Even eliminating the measured consumer entirely
would leave the 89–93 ms render call. Do not turn that hypothetical into an app
speedup claim or replace final detail with the lower-resolution proxy.

One first-in-process decode took **3414.15 / 3480.00 ms**, including
**2599.46 / 2671.64 ms** demosaic. These two one-pass measurements are outside
the render timers, are not a decode benchmark distribution, and cannot be
compared with historical three-pass export timing as equivalent workloads.

## Resource cost and guards

Logical image payloads and Mach measurements are kept separate:

| Quantity | Run A / run B |
|---|---:|
| Full RGB16 source payload | 241,118,208 bytes (229.95 MiB) each |
| Renderer RGBA16 source backing | 321,490,944 bytes (306.60 MiB) each |
| Full diagnostic consumer surface | 160,745,472 bytes (153.30 MiB) each |
| Process peak physical footprint | **810.85 / 813.28 MiB** |
| Full-render physical footprint after output returns, untimed EV +0.4 | 657.45 / 659.89 MiB |
| Physical footprint with the extra consumer surface, same EV | 810.85 / 813.28 MiB |
| Physical footprint after local sources/renderers release | 195.88 / 192.72 MiB |

The process peak is cumulative across decode, earlier cases, warmups and the
untimed diagnostic pass; it is not an isolated GPU allocation or the whole app's
peak. The shared Core Image context remains alive after local release. Resident
and reusable bytes are recorded independently and must not be treated as live
physical footprint. No sustained cache-capacity, memory-pressure response,
leak, or energy conclusion follows from this probe.

Both finalized runs completed four cases: **24 timed samples**, eight warmups,
and 48 separate hash-check renders in total, with zero failed/skipped cases.
Each case/EV was rendered twice in its untimed pass and required identical
consumed RGBA8 hashes. All **12 case/EV hashes also match between processes**.
That is a deterministic-output check, not CPU parity or photographic acceptance.

The freshly run full CPU/Metal comparator separately passed **4,132/4,132 cases**:
**3,796 GPU comparisons within 2/255**, **336 explicit CPU routes**, and **zero
render failures**. The collection validator checked content fingerprints, output
hashes, dimensions, EV sequence, timing arithmetic, medians/nearest-rank p95,
cross-run equality, and both CLI output-safety rejections. Release builds passed.
The full native regression suite, RAW determinism matrix, preference rerenders,
photographic CPU comparisons and exports were not rerun; production sources
are unchanged by this work.

## Ranked decisions and stopping point

1. **Full-resolution C-41 rendering — selected target; profile before changing
   its implementation.** It recurs in both processes, dominates the measured
   warm path, and retains exact full-resolution output. The likely user cost is
   waiting for final refinement, but native input/presentation remains unmeasured.
   Instrumentation effort is bounded; shader, precision or buffer-ownership
   changes carry medium/high correctness risk. No expected saving is quantified.
   Next correlate one real AppModel edit/release with existing submitted,
   displayed, dropped, correction and cache-hit counters. If duplicate complete
   renders occur, eliminate that work first. Otherwise profile graph preparation
   versus GPU execution/materialization inside this render call. Preserve exact
   final parameters, stale-generation rejection, full detail, tone versions,
   CPU/Metal tolerance and the preference checkpoints. This direct probe has no
   app work counters and establishes no duplicate-render defect.
2. **First/uncached app publication — defer until target 1's app correlation.**
   The historical 580.64 ms first-publication and 369.49 ms uncached-switch
   medians retain the source/cohort limitations in the Stage 0 report; they were
   not refreshed. Existing retained-hit and saturated-speculation repairs must
   not be counted again as new opportunities. A focused app-path collection
   should distinguish source tier, queue wait, rendering and publication, with
   retained-memory/cancellation guards. Scheduling changes have medium risk.
3. **Three-pass export decode — defer.** The Stage 0 report's historical warm
   demosaic median of 4.372840 s suggests cost, but the new one-pass decode here
   does not refresh it. A future one-file TIFF stage report must precede decoder
   changes, with stage hashes, serial oracle, writer pixels, cleanup and
   cancellation intact. Decoder work has high correctness risk.

The synthetic stage was unnecessary for this real-RAW question. Stage 2 now
identifies the dominant measured stage, meeting its stopping rule. Broader
app/roll/export batches, screen-presentation traces, color-study migration and
fitting, and controlled energy studies remain deferred. More free disk removes
the earlier resource blocker; it does not make unrelated collection useful for
this optimization decision.
