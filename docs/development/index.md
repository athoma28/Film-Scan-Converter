# Developer Guide

New product work belongs in the native Swift/macOS app. Use
[development status](native-macos.md) for current behavior and evidence and the
[roadmap](../improvements/MacOS-Native-Roadmap.md) for remaining work.

## Keeping Verification Current

Beta 3 includes Film Base / LookRecipe, retained previews, and version-4 tone
and grading controls. The [verification summary](native-macos.md#verification-summary)
distinguishes complete-suite results from later focused checks; a published
binary or older test report does not validate subsequent working-tree changes.

| Question | Maintained source |
|---|---|
| What to run and which inputs/flags are required? | [Test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md) and [Building](building.md) |
| What has actually been checked, and what remains unverified? | [Development status](native-macos.md#verification-summary) |
| How should the app behave? | [Native contracts](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/README.md), [preview architecture](realtime-preview-plan.md), and [Features](../features.md) |
| Can the historical color studies run on today's engine? | [Color evaluation compatibility status](color-evaluation.md) |
| Why was a performance or color decision made? | Dated reports linked below; their numbers apply to the recorded source, settings, corpus, and machine |

When a test or harness changes, update its command in the test guide and record
fresh results in development status. Include source revision/working-tree changes,
environment, cohort, skips/failures, and unrun checks. Preserve dated measurements
and preference ledgers; label superseded behavior rather than rewriting old
evidence as a new run. Documentation-only edits do not require refreshing RAW
fixtures, full color galleries, or every benchmark.

The [September 25 UTC follow-through](roadmap-follow-through-2026-09-25.md)
records the immediate workflow repairs, public-recipe color migration,
photographic output checks, and perspective/frame-ratio changes.

## Build, Test, And Release

- [Building](building.md): Swift toolchain, regression commands, and local launch.
- [Test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md): fixtures, RAW corpus, roll workflow, and
  independent-reader checks.
- [Release runbook](native-release.md): self-contained packaging, signing,
  notarization, and clean-machine validation.
- [Contributing](../contributing.md): source ownership and change requirements.
- [Native package](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/README.md): targets, commands, and contracts.

## Architecture And Performance

- [Slider-to-preview latency](../performance/slider-preview-latency-2026-09-24.md):
  property-level window updates and proxy overviews during zoomed edits, with
  matched native-window latency, full-detail agreement, and refinement limits.
- [Separated tone ranges and grading levels](tone-range-separation-2026-09-24.md):
  distinct Highlights/Whites and Shadows/Blacks response, grading wheel level
  controls, versioned saved edits, and fresh photographic/parity evidence.
- [Ordinary slider response and native interaction](slider-response-study-2026-09-24.md):
  small photographic edits and combinations, collateral color/texture measures,
  and compositor-observed native preview revisions with input scheduling evidence.
- [Editing and retained-image work reuse](../performance/edit-switch-work-reuse-2026-09-23.md):
  memoized diagnostics on cached revisits, statistics-only gesture completion,
  and atomic color-wheel updates, with a bounded real-RAW measurement.
- [RAW draft unpack optimization](../performance/raw-preview-unpack-2026-09-22.md):
  15.2–30.3% lower draft-decode latency on three X-T5 frames, exact pixels,
  contention limits, and app navigation/memory guards.
- [C-41 shared output optimization](../performance/c41-shared-output-2026-09-22.md):
  57.2% lower full-resolution render-and-consume latency in a controlled M4 Pro
  comparison, exact pixels, retained-buffer checks and memory tradeoffs.
- [C-41 refinement measurements](../performance/c41-refinement-discovery-2026-09-22.md):
  completed Stage 2 collection with split render/consumer timing, physical
  footprint, repeated pixel hashes, and a fresh CPU/Metal guard.
- [Optimization target discovery](../performance/optimization-target-discovery-2026-09-22.md):
  source-only metric inventory, provenance checks, and ranked targets that led
  to the subsequent bounded C-41 refinement measurement; no fresh benchmark run
  was part of the discovery pass.
- [Retained-preview performance](../performance/retained-preview-2026-09-19.md):
  fresh app-path navigation and physical-footprint samples, retained-raster
  reuse, and avoiding speculative RAW decodes that a full cache cannot admit.
- [Viewport rendering and work reuse](../performance/viewport-and-work-reuse-2026-09-16.md):
  September 16 measurements of CPU preparation, bounded scratch, visible-region
  rendering, and asynchronous statistics. Its original cache/scheduling policy
  predates the current retained-preview architecture.

- [RAW upgrade compatibility](raw-decode-compatibility.md): X-T5 source geometry,
  color continuity, and unchanged pixel references across LibRaw upgrades.
- [Performance implementation](../performance/implementation-2026-09-13.md):
  background persistence, exact Natural B&W lookup, preview publication,
  analysis reuse, GPU manual crop, and retained-memory accounting.
- [Full-resolution edit scaling](../performance/preview-scale-2026-09-14.md):
  real-RAW render-size measurements and the bounded continuous-edit proxy.
- [Second research pass](../performance/research-pass-two-2026-09-13.md):
  measured settings stalls, an exact B&W lookup prototype, HDR weighting and
  precision counterexamples, and bounded implementation steps.
- [Performance research directions](../performance/research-directions-2026-09-12.md):
  September 12 source findings, interactive-edit repairs, and staged decode,
  GPU preview, and export experiments.
- [B&W tonality investigation](../performance/bw-tonality-2026-09-13.md):
  confirmed flat-curve loss, HDR merge headroom and precision probes, and
  small-region reconstruction experiments.
- [Still preview architecture](realtime-preview-plan.md): image tiers,
  scheduling, viewport, and preview/export boundaries.
- [X-Trans mosaic binning](xtrans-preview-mosaic-binning.md): why requested
  preview bounds produce discrete pixel sizes.
- [40 MP export benchmark](../performance/40mp-export.md): workload definitions,
  stage timing, deterministic decode evidence, and memory/cancellation checks.
- [Preview analysis benchmark](../performance/preview-analysis.md): bounded CPU
  diagnostics and Darkroom analysis, including September 8 sort-reuse measurements.
- [RAW compatibility benchmark](native-raw-benchmark.md): the frozen
  `rawPyCompatibility` decoder evidence, separate from camera-scan export.

Run the CPU/Metal comparator with normal macOS graphics access:

```sh
swift run -c release --package-path native/FilmScanEngine FilmScanPreviewComparator
```

The default run includes the historical parameter grid and current Film Base /
LookRecipe cases, public control endpoints, dye crossover, combined grading, and
Original comparison. Require every declared case to complete, zero render failures,
and maximum GPU RGB channel error at most 2/255. Flat density inputs explicitly
verify CPU routing and are counted separately from GPU comparisons. Missing Metal,
unexpected unsupported cases, failed renderers, invalid bitmap layouts, dimension
mismatches, incomplete cohorts, and excess error fail the gate. `--suite=current` and `--suite=legacy`
select focused subsets. Record the actual counts and suite; results are in the
[verification summary](native-macos.md#verification-summary). Synthetic parity
does not establish photographic quality, reference-study reproduction, control
effectiveness, RAW decode parity, or full-resolution export agreement.

## Supporting Workflows

[Color evaluation against references](color-evaluation.md) is the agent runbook
for the active paired Camera Raw, Pro Image, and segmented-skin studies. It covers
preflight, reproducible renders, fitting, preference preservation, and validation.
It also records the open recipe/schema migration gaps in the study scripts;
passing preflight alone does not establish a successful end-to-end study.

[Photographic tone controls](photographic-tone-controls-2026-09-22.md) documents
the versioned rendering contract, crop interaction, and validation evidence.

[Density-matrix fitting](density-matrix-calibration.md) and
[reference-curve calibration](reference-negative-calibration.md) document
older offline tools and profile provenance. The broader stock/capture calibration
project remains parked under the [research scope](../film-processing-research.md);
the September 18 paired color/control investigation is active.

The [Python application](../legacy-python.md) remains maintenance-only for
applied dust removal, cross-platform/ART workflows, and fixture tools. Frozen
compatibility fixtures govern shared behavior; new native features use Swift
CPU contracts.
