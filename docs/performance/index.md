# Performance evidence and next measurements

Reviewed October 2, 2026; entries updated October 12. This index organizes the native performance records;
the review itself produced no new benchmarks or image renders. The latest
implementation and verification reports describe the recorded working tree,
including uncommitted work. They do not establish what a published app contains.

Use [development status](../development/native-macos.md#verification-summary)
for the latest completed checks and their omissions,
[native contracts](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/README.md)
for behavior, and the [roadmap](../improvements/MacOS-Native-Roadmap.md) for
priority. Start new collection with the
[measurement runbook](../development/data-collection-optimization-target-discovery.md)
and current commands in the
[test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md).

## Latest implementation and decisions

| Record | Status and useful evidence | Limit |
|---|---|---|
| [October 12 non-JPEG export](non-jpeg-export-2026-10-12.md) | Fixed Average PNG filter: 20.9–27.1% lower writer medians and 6.2–11.8% lower complete-export medians; exact 16-bit pixels, five preferences, unchanged TIFF and rejected DNG pointer trial | Three 40 MP X-Trans scans through one C-41 profile; warm filesystem; engine timing excludes app queue/UI; PNG file sizes change by −0.061% to +0.496% |
| [October 11 first detailed cached gesture](detailed-cached-revisit-2026-10-11.md) | Bracketed two-RAW CPU viewport collection: first-revisit publication medians 90.6 ms versus 308.3–311.8 ms; 18 full/overview/detail oracle sets | Three pairs per process; higher physical retention; full release refinement still about one second; broader source cohorts, no isolated causal, Fit, continuous-drag or screen claim |
| [October 11 eight-RAW byte policy](sustained-byte-capacity-2026-10-11.md) | 32 switches, full-session loss below depth eight and a zero pre-simulation pressure-drop count under the normal 3 GiB policy; exact reuse guards and recovery/release | Unexposed admission reservations; no exact capacity ceiling, older-code comparison or OS-pressure claim; unusually low physical readings preserved without attribution |
| [October 11 CPU cached revisit](cpu-revisit-preparation-2026-10-11.md) | Session-owned full/proxy preparation removes a 187–261 ms first-edit penalty in a bracketed two-RAW workload; 30 exact full CPU outputs and cache/pressure/release guards | 15.3–20.9% lower model-publication medians for a CPU geometry fallback; substantially higher settled physical footprint; no general capacity or screen-latency gain |
| [October 11 sustained RAW navigation](sustained-preview-2026-10-11.md) | Eight loops, 24 count-limit evictions, exact revisit pixels, current edits/Original, simulated pressure and verified model release | Single collection; every retained-canvas publication still needed one full decode/correction; residual physical footprint; no OS-pressure, capacity or improvement claim |
| [October 10 three-RAW JPEG export](jpeg-three-export-2026-10-10.md) | Exact X-Trans homogeneity reordering; 32.4–34.3% lower export medians, 45 identical JPEGs, five preferred-look checks, and rejected CPU trials | Three 40 MP X-Trans scans using the same C-41 profile and warm filesystem pages; engine export timing excludes app queue/UI |
| [October 10 JPEG export](jpeg-export-2026-10-10.md) | Bounded parallel photographic conversion; identical full-resolution JPEGs and all five preferred-look replays | Correction-stage gain on one C-41 RAW; strong machine drift prevents a general total-export multiplier |
| [October 2 implementation](implementation-2026-10-02.md) | Exact CPU density lookup, thumbnail workers/shared RAW metadata, two-pass dust closing, resident stack reference, bounded DNG packing, and render invalidation checks implemented; matched baseline/candidate/recheck records | One RAW-derived CPU source, synthetic dust/I/O cases, eight landscape thumbnail inputs; no end-to-end screen or general export-throughput claim |
| [October 2 discovery](opportunities-2026-10-02.md) | Historical source audit leading to that implementation; straightforward parallel RGBA8 packing measured and rejected | Its six ranked implementation items are completed follow-ups, not a current to-do list |
| [September 28 CPU follow-up](cpu-point-work-2026-09-28.md) | Scalar initial conversion and correction at the requested overview size; matching full/detail/overview and branch hashes | Quieter-machine repeatability remains open; contended additional-frame timings excluded |
| [September 27 implementation](implementation-2026-09-27.md) | Prepared CPU state, CPU viewport path, deferred RGBA backing, auxiliary workers, independent export writers | First geometry warp excluded from CPU timings; deferred allocation and writer overlap are not measured sustained-memory or throughput gains |

The October 2 report records a bounded CPU density-render improvement and a
synthetic dust-detector improvement. DNG evidence supports a transient writer
peak reduction; variable writer/stack timings do not establish general
throughput gains. Thumbnail work placement and stale-stage rejection have
correctness evidence, with user-visible latency measurements still open.

## Measurement questions still open

These are scoped questions for choosing a future experiment. They are not
authorization to implement every candidate or change final quality/defaults.
Select one with the runbook's stopping rule and the roadmap's priorities.

| Question | Existing evidence | Smallest useful next measurement |
|---|---|---|
| How much do thumbnail workers help during import while editing? | October 2 worker isolation and exact thumbnail hashes; extraction medians do not show a general gain | Count RAW opens and main-actor blocked time, selected-preview publication/capture latency; include rotated files and metadata failure |
| How much obsolete rendering remains during rapid selection/geometry changes? | October 2 context-invalidation tests preserve single-worker draining and point-edit publication | Correlate invalidated-stage counts, completed-but-unused work, and latest-preview latency in CPU fallback navigation |
| How far does the cached CPU preparation benefit transfer? | [Committed edits](cpu-revisit-preparation-2026-10-11.md) and [first detailed gestures](detailed-cached-revisit-2026-10-11.md) show bounded two-RAW CPU benefits with higher physical retention; the [eight-RAW collection](sustained-byte-capacity-2026-10-11.md) records eviction under the normal byte policy | Other photographs/machines and continuous gestures with physical/release guards; separate native input and screen presentation from model publication |
| Can initial photographic conversion improve further? | October 10 bounded workers are already implemented; later three-RAW prepared/fused CPU trial was retired after profile-stage regressions | Inspect ordinary release code and identify a new measured bottleneck before another exact-output experiment |
| Can the remaining export writers improve further? | [October 12 PNG implementation](non-jpeg-export-2026-10-12.md) reduces fixed-filter work; DNG pointer packing saved only 2–5 ms and was rejected; default uncompressed TIFF writing was about 0.11 s | Other PNG content/machines and compressed TIFF writing with exact samples/profile, output-size, cleanup and memory guards |
| Does standard-image writer overlap improve throughput? | September 27 overlap/cancellation tests; RAW intentionally exports sequentially | Matched standard-image format/size cohort with output, cleanup and peak-memory guards |
| What is settled retained-cache capacity under memory pressure? | [Three-RAW count eviction](sustained-preview-2026-10-11.md) and [eight-RAW byte-policy eviction](sustained-byte-capacity-2026-10-11.md) cover simulated app pressure/recovery and release | Controlled OS pressure and recovery, other machines and explicit admission/native-work instrumentation; keep accepted results separate from cancelled native starts |
| What is today's interaction/refinement cost after later engine changes? | September 24 compositor-observed setter replay, separate from native pointer input/physical scan-out | Repeat that workload on a frozen current binary, then add native-input timestamps only if needed |
| What are energy and thermal costs? | No controlled energy study in these reports | Fix power/display/idle conditions and duration after selecting a repeatable latency or memory workload |

The calibrated-color input-lookup idea in the September 28 report is separate
from the October 2 density-print lookup. It requires its own release-code
inspection and exactness/amortization study. The rejected RGBA8 packing trial
is evidence against that particular implementation, not every possible packing
strategy. Avoid proposing either as an unmeasured guaranteed speedup.

## Earlier evidence by workflow

| Workflow | Records | Interpretation |
|---|---|---|
| Native editing and observation | [September 24 slider latency](slider-preview-latency-2026-09-24.md), [September 23 work reuse](edit-switch-work-reuse-2026-09-23.md), [coalesced persistence](settings-persistence-implementation.md) | Distinguishes setters, model publication, captured compositor revisions and persistence; later schema/render changes need current checks |
| RAW browsing | [September 22 draft unpack](raw-preview-unpack-2026-09-22.md) | Three-frame X-T5 decode comparison, exact stage/pixel guards, rejected unrestricted concurrency and retained contention policy |
| C-41 GPU refinement | [September 22 source inventory](optimization-target-discovery-2026-09-22.md) → [bounded collection](c41-refinement-discovery-2026-09-22.md) → [shared output](c41-shared-output-2026-09-22.md) | Discovery, baseline measurement and matched implementation are distinct; diagnostic consumption is not app screen presentation |
| Retention and preview scale | [September 19 retained previews](retained-preview-2026-09-19.md), [September 14 scaling](preview-scale-2026-09-14.md) | Removes rejected speculation and bounds active-edit work; later CPU viewport/overview changes supersede the original fallback routing |
| CPU analysis | [September 4/8 preview analysis](preview-analysis.md) | Bounded statistics and percentile-sort reuse with exact references; isolated stage measurements |
| Export and RAW determinism | [40 MP export benchmark](40mp-export.md), [RAW compatibility benchmark](../development/native-raw-benchmark.md) | Current commands plus dated design evidence; camera-scan three-pass export and RawPy compatibility are different contracts |
| B&W quality investigation | [September 13 tonality](bw-tonality-2026-09-13.md) | Historical synthetic mechanism/reconstruction research; the reported photographic symptom remains unconfirmed and this is not default-change authorization |

## Evidence availability and provenance

Committed reports under `docs/performance/` are readable in a clean checkout.
Named local artifacts under ignored `dist/` and private
inputs under ignored `sample-raw/` are listed as repository-relative code paths,
not website links. They are available only on machines that retain those files;
a fresh clone or published documentation site does not contain them. Missing
local artifacts mean the associated measurements cannot be independently
recomputed there from the prose alone. Do not substitute a neighboring private
frame or quietly recreate a historical output path.

Superseded snapshots removed from the current tree remain in Git history.
For example, the September 4/8 raw analysis samples and the September 13
synthetic follow-up can be inspected at revision
`d80644d1c0e43273541a89465eeac53291ccc370`:

```sh
git show d80644d1c0e43273541a89465eeac53291ccc370:docs/performance/preview-analysis-2026-09-04.json
git show d80644d1c0e43273541a89465eeac53291ccc370:docs/performance/darkroom-sort-reuse-2026-09-08.json
git show d80644d1c0e43273541a89465eeac53291ccc370:docs/performance/research-pass-two-2026-09-13.md
```

The report date, source/dirty-state fingerprint, harness, binary, input/settings,
machine, source tier and stage boundaries define its measurement cohort. A new
run on changed source is a new cohort. Keep every sample, failure, exclusion,
rejected candidate and quality guard alongside the accepted summary. Never add
percentages measured on different stages/cohorts into an app-wide improvement.

## Updating this collection

For a new investigation, name a dated report after the workflow/question and
state whether it is source inspection, a baseline collection, a rejected trial,
or an implementation comparison. Include the exact result and its scope early;
follow with provenance, reproducible commands, raw-evidence paths, numerical and
photographic guards, failures/exclusions, and remaining unrun checks. Use the
runbook's scorecard and reporting fields to keep reports comparable.

When a follow-up completes an opportunity, add its link and status to the older
record and update this index's open questions. Keep the older measurements and
their original meaning. Update current contracts/status and the test guide if
behavior or commands changed. A documentation-only pass should record link and
source checks separately from fresh engine, benchmark or photographic evidence.
