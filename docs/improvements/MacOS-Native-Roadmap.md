# Native macOS Product Roadmap

This is the ordered plan for remaining product work. Implemented capabilities
and dated validation belong in [development status](../development/native-macos.md);
user-facing behavior belongs in [Features](../features.md).

Reviewed against the local working tree on October 11, 2026 UTC. These priorities
target remaining source behavior after Beta 3. Film Base / LookRecipe,
retained previews, bounded neighbour warming, version-4 tone controls, and
priority RAW scheduling are implemented. The immediate workflow repairs and
perspective/framing improvements are complete; the
[September 25 validation](../development/roadmap-follow-through-2026-09-25.md)
records photographic Metal comparisons, full-resolution exports, the migrated
color study, and remaining limits.
The later September 27–October 2 performance implementations are also complete
source work; their bounded evidence and further candidates are in the
[performance index](../performance/index.md). A documentation review does not
rerun the recorded checks or establish acceptance for a newer binary.

Distribution is last at the owner's request. Real repeated-capture quality
validation is explicitly pending until independent rescans/brackets are available.

The product is a fast, flexible, trustworthy film-scanning workflow: import,
judge, adjust, transfer a look across a roll, and export predictable files.
New work must prevent incorrect results, improve that frequent workflow, close
a measured performance problem, or establish distribution evidence.

Computer Use testing was deferred at the owner's request in the recorded
validation work. Automated and file-based verification continue; the photographic
and distribution acceptance below remains open.

## 0.3 Workflow Scope

The September 30 source work adds selective adjustment sync/paste, original-folder
export defaults with per-job destination snapshots, and opt-in dust repair.
Dust identification remains separate from image changes: editable masks feed
explicit automatic repair, while a healing brush supports automatic or chosen
texture sources. Repairs persist in source coordinates and survive framing edits.
October 3 source work adds recovery of the open roll, sidebar order, primary
selection, and multiselection, including unavailable paths on disconnected drives.
Close All Scans starts an empty roll while preserving per-image corrections.
Transient history/previews, enabled stacks, and export jobs do not restore.

The [October 10–11 development loop](../development/roadmap-loop-2026-10-10.md)
adds every-save settings validation and recovery, late export collision handling,
automatic/manual donor and mask-consumption guards, separate async action history,
stale Auto Frame rejection, export preparation cancellation, and session-owned
CPU preparation. Its sustained navigation and
matched CPU-revisit studies establish bounded automated evidence; the CPU edit
benefit has a higher settled physical-memory cost. These are completed workflow
repairs, while the acceptance decisions below remain open.

Before release, judge detection false positives and healing on real grain,
edges, skin, fine texture, and difficult backgrounds at full resolution.
The initial repair operator uses CPU fallback and conservative component limits;
synthetic correctness and reopened-file checks do not establish photographic
restoration quality. Continue the packaged/photographic and distribution
acceptance sequence below. Current verification is recorded in development status.

## Active Color/Control Follow-Up

The September 18 Camera Raw/Pro Image/skin work is distinct from the parked
stock/capture calibration project. Its current workflow now uses canonical film
bases and public-control recipes, current native variant names, schema-2 preset
publication, and exact app-applied pixel checks. A fresh complete run covers 40
registered pairs, five frozen preferences, and 11 full-resolution study exports.

Use the [color evaluation runbook](../development/color-evaluation.md) for future
work. Thirteen frame-specific skin candidates passed training-based selection;
individual-region regressions and failed transfers remain documented. User
feedback and independent whole-profile validation are still required before
changing defaults. Factory recipes and the preference ledger were preserved.

The next decision is photographic review of those candidates, followed by a
bounded validation on unseen photographs if a candidate is worth pursuing.
Neither a lower reference error nor a completed migration authorizes promotion
to a stock-wide/default recipe. The [research index](../research/index.md)
separates this active question from parked profile calibration.

## Validation Sequence

### 1. Verify Photographic Judgment In The Packaged App

Fit, 100%, pan, comparison, and manual-crop gesture mechanics have passed local
packaged checks. Automated viewport and geometry regressions also pass.
Remaining work is hands-on judgment across representative images:

- assess focus, grain, dust, fine tonal transitions, clipping, and color;
- inspect Original comparison and draft/inspect/full-resolution transitions;
- exercise crop, straighten, perspective, and their reset/undo behavior;
- check current Film Base/preset application, visible slider state, Reset
  Adjustments, clipboard transfer, saved-preset migration, tone-version promotion,
  grading levels, and undo/redo;
- confirm that the preview and reopened full-resolution result agree within
  the documented source-resolution and bit-depth boundaries.

Acceptance is a recorded photographic assessment and repairs for any concrete
workflow or image defect it exposes.

### 2. Validate A Realistic Roll And Real Repeated Captures

The refreshed three-frame RAW workflow passed look transfer, exceptions,
undo/redo, comparison, three reopened TIFFs, decode reuse, and persisted settings.
A packaged stack check using duplicate JPEGs verifies mechanics only.

Real Noise/HDR photographic validation is pending by owner request. When a
repeated-capture cohort is available, use a real roll to establish an anchor look, apply it to selected frames,
correct outliers, inspect real Noise/HDR stacks, select outputs, and export.
Verify immediate visible changes, per-frame geometry/base preservation,
import order, one output per enabled stack, errors, and cancellation. Check
stack quality on independently captured images, including exposure brackets.
Add organization features only if this workflow demonstrates a need.

## Standing Regression Requirements

The [native contracts](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/README.md#implementation-contracts)
own processing, preview/memory, saved-edit migration, repair, geometry, queue,
and persistence invariants. The
[test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md)
owns their commands and opt-in gates; [development status](../development/native-macos.md#verification-summary)
owns results. Keep those owners current when changing behavior rather than
maintaining a second contract copy in the roadmap.

Performance work requires a measured bottleneck, identical workload/quality in
before/after runs, physical-footprint reporting, and equivalence checks. The
[performance index](../performance/index.md) identifies the applicable evidence
and limits. Historical baselines must be remeasured against current source before
claiming a present-day gain. Completed optimizations and source-audit repairs are
recorded evidence, not pending roadmap items.

## Evidence-Driven Product Candidates

- Further preview tiling using an established interpolator, if profiling finds
  slow full-detail edits after retained-raster navigation and existing transient
  region rendering are accounted for.
- Further dust restoration quality work beyond the initial editable-mask/healing
  implementation, supported by representative real scans.
- Film-edge assistance or broader batch organization when a
  real photographic workflow needs them.
- Calibration beyond one planar perspective warp, supported by repeatable
  geometric defects in real scans.
- Stage-based progress estimates that outperform current progress reporting.

## Parked: Stock And Capture Look Calibration

Existing Natural/Darkroom profile code, capture/stock/roll types, and offline
fitters retain their recorded provenance. They are not the current factory preset
menu. The broader corpus-preparation/named-stock calibration project, residual
LUTs, halation simulation, stock classification research, and ML are dormant.
Re-entry requires explicit owner direction, a concrete photographic question,
licensed representative pairs, held-out validation, and a bounded maintenance
budget. See [research scope](../film-processing-research.md).

## Outside The Current Plan

Novel X-Trans or learned demosaic, a three-pass Metal rewrite, live RawTherapee
float parity, speculative three-pass export-quality RAW prefetch, unmeasured writer
replacement, vendor tethering without hardware/demand, and expansion of the
Python product are outside the plan.

Bounded one-pass full-sensor preview lookahead is already implemented and is
distinct from prefetching authoritative export decodes.

[Python retirement](../legacy-python.md) follows supported-workflow replacement
and distribution proof; it does not gate a sound native release.

## Last Priority: Distribution And Independent-Mac Acceptance

Automated ImageIO/`sips` checks cover TIFF/JPEG/PNG color tags, bit depth,
dimensions, and orientation; DNG tests cover its processed-RGB tag contract.
Local app/ZIP assembly and validation work.

Deferred at the owner’s request; remaining acceptance:

- judge exports in Preview/Photos and a suitable processed-DNG reader;
- assemble the final artifact from its release commit with green CI;
- Developer ID sign, notarize, staple, and pass Gatekeeper;
- install and launch on a supported Mac without Homebrew or the source checkout;
- repeat import/edit/compare/export/reopen, camera permission, settings,
  cancellation, collision, and relaunch checks;
- record the exact version/build, artifact hash, platform, and results.

The [release runbook](../development/native-release.md) owns the procedure.
