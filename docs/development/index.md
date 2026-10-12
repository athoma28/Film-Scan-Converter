# Developer Guide

New product work belongs in the native Swift/macOS app. Use
[development status](native-macos.md) for current behavior and evidence and the
[roadmap](../improvements/MacOS-Native-Roadmap.md) for remaining work.

Use the [research index](../research/index.md) to find active investigations,
completed output-control evidence, and parked calibration scope. Use the
[performance index](../performance/index.md) for the measurement history and
remaining experiments. The [documentation maintenance guide](documentation-maintenance.md)
defines ownership, evidence retention and checks for future changes.

## Keeping Verification Current

Beta 3 includes Film Base / LookRecipe, retained previews, and version-4 tone
and grading controls. The 0.3.0 Beta 1 release adds selective adjustment transfer,
source-folder export defaults, editable dust masks with optional repairs, and
open-roll restoration with Close All Scans.
The [verification summary](native-macos.md#verification-summary)
distinguishes complete-suite results from later focused checks; a published
binary or older test report does not validate subsequent working-tree changes.

| Question | Maintained source |
|---|---|
| What to run and which inputs/flags are required? | [Test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md) and [Building](building.md) |
| What has actually been checked, and what remains unverified? | [Development status](native-macos.md#verification-summary) |
| How should the app behave? | [Native contracts](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/README.md), [preview architecture](realtime-preview-plan.md), and [Features](../features.md) |
| Can the historical color studies run on today's engine? | [Color evaluation compatibility status](color-evaluation.md) |
| Why was a performance or color decision made? | [Performance evidence](../performance/index.md) and [research registry](../research/index.md); dated numbers apply to the recorded source, settings, corpus, and machine |

When a test or harness changes, update its command in the test guide and record
fresh results in development status. Include source revision/working-tree changes,
environment, cohort, skips/failures, and unrun checks. Keep dated reports that
support current claims or decisions, and preserve the user-preferred color
checkpoints. Git history retains superseded snapshots. Never present an older
measurement as a fresh run. Documentation-only edits do not require refreshing RAW
fixtures, full color galleries, or every benchmark.

The [September 25 UTC follow-through](roadmap-follow-through-2026-09-25.md)
records the immediate workflow repairs, public-recipe color migration,
photographic output checks, and perspective/frame-ratio changes.
The [October 10–11 roadmap loop](roadmap-loop-2026-10-10.md) records settings
recovery, export collisions, automatic dust-repair checks and fresh native
workflow validation.

## Build, Test, And Release

- [Building](building.md): Swift toolchain, regression commands, and local launch.
- [Test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md): fixtures, RAW corpus, roll workflow, and
  independent-reader checks.
- [Release runbook](native-release.md): self-contained packaging, signing,
  notarization, and clean-machine validation.
- [Contributing](../contributing.md): source ownership and change requirements.
- [Native package](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/README.md): targets, commands, and contracts.

## Architecture And Current Evidence

The [performance index](../performance/index.md) maps earlier discovery reports
to subsequent implementation, rejected candidates, and remaining experiments.
Start there for the complete history; the links below support current contracts.

- [October 2 performance implementation](../performance/implementation-2026-10-02.md):
  exact density lookup, two-pass dust closing, thumbnail workers, bounded DNG
  packing, stack reference reuse, and invalidated preview-stage checks.
- [October 12 non-JPEG export](../performance/non-jpeg-export-2026-10-12.md):
  faster lossless PNG filtering, matched full-resolution measurements, unchanged
  TIFF/DNG writers, fresh preferences and rejected DNG packing work.
- [October 2 performance discovery](../performance/opportunities-2026-10-02.md):
  source audit that led to the completed implementation, with a measured RGBA8
  packing candidate rejected for regressions; remaining questions are in the index.
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
- [RAW upgrade compatibility](raw-decode-compatibility.md): X-T5 source geometry,
  color continuity, and unchanged pixel references across LibRaw upgrades.
- [Full-resolution edit scaling](../performance/preview-scale-2026-09-14.md):
  real-RAW render-size measurements and the bounded continuous-edit proxy.
- [CPU point correction and viewport overviews](../performance/cpu-point-work-2026-09-28.md):
  scalar channel work, correction at the requested overview size, exact output
  checks, bracketed full-source timings and excluded contended proxy samples.
- [September 27 performance implementation](../performance/implementation-2026-09-27.md):
  CPU viewport correction, prepared rendering state, deferred GPU backing,
  auxiliary workers, and independent export writers with bounded measurements.
- [Still preview architecture](realtime-preview-plan.md): image tiers,
  scheduling, viewport, and preview/export boundaries.
- [X-Trans mosaic binning](xtrans-preview-mosaic-binning.md): why requested
  preview bounds produce discrete pixel sizes.
- [40 MP export benchmark](../performance/40mp-export.md): workload definitions,
  stage timing, deterministic decode evidence, and memory/cancellation checks.
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
The current workflow uses canonical Film Base and public LookRecipe controls;
see the [verification summary](native-macos.md#verification-summary) for completed
runs and remaining limits.

[Photographic tone controls](photographic-tone-controls-2026-09-22.md) records
the version-2 implementation. The [separated tone-range study](tone-range-separation-2026-09-24.md)
documents the later version-4 response used by new neutral edits.

[Density-matrix fitting](density-matrix-calibration.md) and
[reference-curve calibration](reference-negative-calibration.md) document
older offline tools and profile provenance. The broader stock/capture calibration
project remains parked under the [research scope](../film-processing-research.md);
the September 18 paired color/control investigation is active.

The [Python application](../legacy-python.md) remains maintenance-only for
applied dust removal, cross-platform/ART workflows, and fixture tools. Frozen
compatibility fixtures govern shared behavior; new native features use Swift
CPU contracts.
