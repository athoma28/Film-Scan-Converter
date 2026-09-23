# Data collection and optimization target discovery

Prepared 2026-09-22 as a reusable, resource-aware step. This runbook records
what to collect before choosing the next optimization. It does not authorize
changing processing defaults, regenerating reference fixtures, or treating
historical reports as a fresh baseline.

## Purpose and current finding

The regular native regression suite establishes correctness, pixel consistency,
work scheduling, and selected cache and memory invariants. CI also reports code
coverage. Most timing, physical-memory, real-RAW, and extended image-quality
measurements live in opt-in benchmarks or separate diagnostics; CI does not run
those gates by default. The repository already has useful counters and
signposts, so the first collection pass should harvest existing evidence before
adding instrumentation.

As of this runbook's preparation, the checkout contained active local source,
test, and documentation changes. Existing dated reports remain evidence for
their recorded source, machine, settings, and inputs only. No fresh measurements
were produced for this runbook.

The outcome of a future collection pass is a short ranked list of optimization
targets, each tied to a repeatable workload, measured benefit, resource cost,
and quality guard. Do not optimize a metric in isolation when it can harm a
photographic preference or another workflow.

## Start here

Use these maintained guides as the source of commands and contracts:

- [Developer guide](index.md) and [Building and testing](building.md)
- [Native package and benchmark commands](../../native/README.md)
- [Test-suite inventory and benchmark switches](../../tests/README.md)
- [Current verification status](native-macos.md)
- [Preview architecture](realtime-preview-plan.md)
- [Color-evaluation compatibility and measurement rules](color-evaluation.md)
- [40 MP export measurements](../performance/40mp-export.md)
- [Retained-preview measurements](../performance/retained-preview-2026-09-19.md)
- [Preview-analysis measurements](../performance/preview-analysis.md)
- [Preview-scale measurements](../performance/preview-scale-2026-09-14.md)
- [Recent tone-control audit](tone-controls-audit-2026-09-22.md)

Check current test switches in tests/README.md before running anything. Setting
one benchmark switch runs only the named measurement; it does not enable the
other opt-in cases.

## Resource rules

This work is deliberately staged. Stop after any stage if its result already
identifies a useful target or if the machine is short on time, free disk, memory,
or thermal headroom.

1. Begin with source and existing reports. This stage needs no RAW decoding,
   exports, galleries, or new benchmark build.
2. Run one small synthetic case only if existing evidence leaves a specific
   question. Avoid compiling a new release product merely to fill a metric
   inventory.
3. Move to one representative RAW only when a candidate depends on real decode,
   preview, or export behavior.
4. Run larger app-path, roll, color, or energy studies only when the earlier
   results justify their cost.
5. Keep compact JSON, logs, and manifests in /tmp or a specifically budgeted
   ignored output folder. Keep generated images, exports, and private scans in
   ignored sample-raw/ and dist/. Never add those artifacts to Git.
6. Estimate free space before a run that creates images. The full color-study
   workflow can generate multiple gigabytes; its plan command is not a substitute
   for resolving the documented recipe/schema integration gaps.
7. Do not purge caches or claim a physically cold disk unless the method actually
   guarantees it. Record first-run and warm-filesystem samples separately.

Do not run all benchmark switches as a batch. Preserve unrelated working-tree
changes and write each report to a fresh path.

## Measurement catalog

The table separates metrics already exposed by tests or tools from new signals
that could help select future work. The “priority” is a suggested collection
order, not a product roadmap.

| Area | Signals already available | Additional measurements to consider | Priority |
|---|---|---|---|
| Editing responsiveness | AppModel preparation, queue wait, render time, interaction-to-publication latency, publication gaps, submitted/displayed/dropped snapshots; app signposts for render stages | Real input-to-presented-frame latency, presented-frame cadence during drags, p50/p95/max interaction latency, stalls and dropped-frame ratio by control and source tier | Highest |
| Preview work efficiency | Full-resolution decode, correction, rendered-cache-hit, lookahead submission and cache-byte counters | Cache hit/miss rates by tier; requests cancelled before decode, cancelled during decode, completed-but-unused work; decode/correction work per published frame | High |
| Navigation and retained memory | First/cached/uncached switch timings, cache fill, logical bytes, process physical/peak footprint in selected app-path runs | Longer-roll settled capacity, eviction/reload cost, latency and physical-footprint curves under memory pressure, selected-file memory headroom | High |
| RAW decode | Decode stage timings, stage-boundary hashes, serial/parallel agreement, camera and dimensions in RAW tools | Milliseconds per megapixel by decode stage and sensor class; throughput and cancellation latency under foreground/background contention | High |
| Export | Decode/process/write stages, queue completion, output size/hash, cancellation, physical and peak footprint, heap snapshots | Time and bytes per megapixel by format; throughput across formats and image sizes; peak live memory per job; queue wait versus active-work time | High |
| Image tone and color | Pixel hashes and CPU/Metal parity; sampled luminance percentiles and per-channel clipping; selected reference MAE and color-study region scores | Highlight/shadow headroom and clipping by channel; signed color bias plus absolute error by region; explicit non-skin controls; controlled texture/detail proxies | High after study migration |
| Robustness and workflow | Decode/export failures, progress, cleanup, cancellation ordering, input hashes, preference checkpoints | Failure and retry rates across a defined corpus; cancellation response at each stage; export artifact size and cleanup verification at scale | Medium |
| System cost | Physical footprint and limited process-memory samples | Energy per 100 MP or completed export, CPU/GPU utilization, thermal state and sustained throughput | Later |
| Test health | Swift code coverage, test counts, skipped cases, suite duration | Per-suite duration trend and flaky/timeout frequency; keep suite duration separate from app latency | Medium |

### Existing instrumentation worth reusing

- AppModel render statistics already split preparation, queue wait, render,
  interaction-to-publication latency, and publication gaps. These describe model
  publication; they do not include physical screen presentation.
- AppPerformanceSignposts labels queueing, settings/classification, decode,
  correction, geometry, writing, cleanup, preview conversion, analysis, GPU
  rendering, and display publication stages. Instruments can correlate those
  events by file and correlation identifier.
- Preview statistics report bounded luminance and clipping samples. Their unit
  tests validate calculation behavior; they are not broad acceptable-quality
  thresholds for every rendered photograph.
- Preview and export benchmarks distinguish logical cache bytes, resident size,
  physical footprint, peak footprint, and reusable heap bytes. Keep those
  quantities separate in reports.
- RAW and export tools already retain hashes and per-stage values. These can
  serve both as optimization evidence and as correctness guards.

## Collection sequence

### Stage 0: source-only inventory

This is the recommended first session when time or disk is constrained.

1. Record the current commit, dirty-file list, macOS and hardware, Swift/Xcode
   version, LibRaw version, and available memory and disk space.
2. Read the current verification summary and the relevant benchmark note. Write
   down the source revision and workload behind any historical number.
3. List available benchmark switches, required local inputs, output paths, and
   their actual assertions. Mark each measurement as one of:
   - default test assertion;
   - opt-in test assertion;
   - opt-in report-only measurement;
   - standalone diagnostic;
   - proposed signal not yet collected.
4. Inspect existing small JSON reports before creating new ones. Reuse them for
   discovery, but label them historical when the source, harness, input, or
   environment differs.
5. Select one candidate target and one workload. Do not run anything just to
   make the inventory look complete.

Deliverable: a compact metric inventory and a reasoned choice of the next
measurement stage. Do not create image artifacts in this stage.

### Stage 1: one low-cost synthetic measurement

Choose one question and one harness. Examples include a focused Darkroom
analysis case, Natural B&W lookup timing, a CPU pipeline microbenchmark, or a
renderer burst. See tests/README.md for the exact switch and filter for each.
Use release mode and serial test execution when comparing timing. Reuse an
existing compatible release build where possible; a rebuild can cost both time
and disk.

Capture the raw samples and output, not only a mean. Confirm whether the harness
has a hard threshold or merely prints a result. Synthetic timing is useful for
isolating an operator, but it does not establish real-RAW app responsiveness or
photographic quality.

### Stage 2: one representative RAW path

Choose only the path related to the candidate:

- Preview tier, crop, or edit-proxy questions: use PreviewScalePerformanceTests
  on its documented RAF, or the app-path preview benchmark if at least four
  suitable RAFs are present.
- Decoder, processing, writer, or peak-memory questions: use
  FilmScanExportBenchmark on one explicitly selected RAF and the smallest useful
  format set. It removes each generated output after hashing it; retain the JSON
  report only.
- Serial/parallel decoder correctness questions: use its determinism mode and
  stage-boundary digests, recognizing that this mode writes a temporary TIFF per
  repetition before removing it.
- Full app queue and cancellation questions: use AppPathExportPerformanceTests
  only after confirming the private corpus, memory, and runtime budget.

Start with one selected frame or the smallest supported cohort. Record exact
relative paths and input hashes. Expand to more cameras, stocks, formats, or
scenes only if the first result leaves uncertainty about generality.

### Stage 3: real interaction and sustained resource behavior

Existing app-path tests time AppModel publication and use a small number of
repetitions. They do not measure mouse delivery or actual presentation on
screen. For a user-visible target, add a separately documented Instruments or
native-app capture that records a real control gesture through presented frames.
Keep model publication and screen presentation as separate timestamps.

For retained previews, use a long enough navigation sequence to observe settled
cache contents, eviction, reloads, background work, and memory-pressure response.
Sample physical footprint during and after work and after model release. The
current depth samples describe initial lookahead population; do not interpret
them as a fully populated cache.

Measure energy and thermal behavior only after latency and memory targets are
clear. Fix display conditions, power source, run duration, and idle baseline.
Repeat runs sequentially and record thermal state; otherwise comparisons can
reflect host conditions rather than the code.

### Stage 4: image-quality measurements

Use the color-evaluation runbook before fitting presets, comparing Camera Raw,
changing defaults, or interpreting gallery results. First resolve its current
recipe/schema migration gaps. The orchestration tests do not render images and
the saved historical galleries are not fresh evidence for the current engine.

When the workflow is ready, choose a small deterministic cohort with verified
registration and content hashes. Include held-out regions or frames, inspect
individual skin regions and non-skin controls, and preserve the preferred-look
checkpoints. Report a vector of measurements rather than one scalar:

- display-space RGB absolute error and signed channel bias;
- luma and chroma errors, with the color space and normalization stated;
- per-channel clipping, luminance percentiles, and monotonicity/headroom checks;
- region-level skin and explicit non-skin patch results;
- selected structure/detail proxies when the reference supports them;
- per-frame and held-out results, failures, exclusions, and preference review.

RGB MAE is not Delta E or calibrated color truth. A per-frame fit is not
validation of a reusable profile on unseen photographs. Do not select a global
correction from a training score alone.

## Comparing runs

Each report should make it possible to reproduce and interpret the measurement:

- source commit and dirty-file summary; hashes of the harness and relevant
  binaries where available;
- macOS, machine model, memory, Swift/Xcode, LibRaw, and graphics availability;
- workload path, dimensions, format, crop, settings, source tier, and input hashes;
- warm/cold label and cache conditions; state explicitly if the filesystem cache
  was not controlled;
- repetitions and every raw sample; median, nearest-rank p95, and maximum when
  useful;
- failure, skip, incomplete-case, and cancellation counts;
- logical bytes, resident size, physical footprint, peak footprint, and reusable
  allocator bytes in distinct fields;
- output hashes, output sizes, and quality checks needed to establish equivalent
  results.

Use median and raw samples for small runs. With only three or five samples, p95
is effectively the slowest observation and is a descriptive marker, not a stable
tail-latency estimate. Do not make a performance claim from the full test-suite
duration.

Before comparing versions, keep the source, workload, format, graphics mode,
cache state, and measurement method fixed. If any changes, call it a new
measurement cohort. Existing controls such as CPU/Metal parity and RAW hashes
must remain satisfied before interpreting a speed gain.

## Choosing an optimization target

For each candidate, fill in this scorecard:

~~~text
Target:
User-visible symptom or engineering cost:
Measured workflow and cohort:
Baseline source/environment:
Relevant stage or bottleneck:
Latency/throughput result (raw samples, median, p95, maximum):
Work counters (submitted, completed, dropped, reused, cancelled):
Memory/energy/disk cost:
Quality and correctness guard:
Observed repeatability and limitations:
Likely implementation effort and risk:
Decision: optimize / measure again / defer
~~~

Prioritize targets that recur in real workloads, have a measurable user or
resource impact, and have a clear correctness and image-quality guard. Prefer
reducing unnecessary work before making a costly operation faster. If two
candidate changes trade quality for speed, record the trade explicitly rather
than hiding it in a combined score.

## Future benchmark work to consider

These are candidate additions after the staged collection identifies a gap:

1. A compact benchmark manifest that normalizes per-harness provenance and emits
   a single index of existing JSON reports without copying image artifacts.
2. A selected-input benchmark lane that records preview/edit latency, export
   stage timings, work counters, and process physical footprint for the same
   source cohort.
3. A frame-presentation probe that correlates real input, model publication, and
   presented frame timestamps during common sliders, zoom, pan, and selection.
4. A sustained-roll cache test with settled-capacity and memory-pressure phases,
   reporting evictions, reloads, wasted speculative work, and user-visible
   latency.
5. A per-format export matrix for throughput, output bytes, peak memory,
   cancellation response, and independent-reader correctness.
6. A representative photographic scorecard for tonal headroom, regional color
   bias/error, non-skin preservation, and carefully selected texture/detail
   measures, with preference checkpoints kept separate.
7. A controlled energy/thermal study once repeatable latency and memory
   workloads have been selected.

Do not implement every candidate by default. Let the initial evidence determine
which measurements can change the next optimization decision.
