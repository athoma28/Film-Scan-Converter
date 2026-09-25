# Native macOS Product Roadmap

This is the ordered plan for remaining product work. Implemented capabilities
and dated validation belong in [development status](../development/native-macos.md);
user-facing behavior belongs in [Features](../features.md).

Reviewed against the local working tree on September 25, 2026 UTC. These priorities
target remaining source behavior after Beta 3. Film Base / LookRecipe,
retained previews, bounded neighbour warming, version-4 tone controls, and
priority RAW scheduling are implemented. The immediate workflow repairs and
perspective/framing improvements are complete; the
[September 25 validation](../development/roadmap-follow-through-2026-09-25.md)
records photographic Metal comparisons, full-resolution exports, the migrated
color study, and remaining limits.

Distribution is last at the owner's request. Real repeated-capture quality
validation is explicitly pending until independent rescans/brackets are available.

The product is a fast, flexible, trustworthy film-scanning workflow: import,
judge, adjust, transfer a look across a roll, and export predictable files.
New work must prevent incorrect results, improve that frequent workflow, close
a measured performance problem, or establish distribution evidence.

Computer Use testing was deferred at the owner's request in the recorded
validation work. Automated and file-based verification continue; the photographic
and distribution acceptance below remains open.

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

Maintain deterministic CPU/export pixels and the
[frozen three-pass camera-scan oracle](../development/raw-decode-compatibility.md).
Preserve bounded latest-value-wins preview work, one authoritative RAW
export decode at a time, selected-file export-cache invalidation, safe cancellation,
collision handling, and cleanup. Geometry edits and comparison share coordinate
semantics; upstream geometry changes invalidate dependent canvas crops.

Completed 1-pass full-sensor previews and corrected rasters may survive navigation
within the RAM/count budget. Speculative work reserves display space and must not
evict useful cached entries; memory pressure drops unselected entries and suspends
speculation. Preserve revision-based render invalidation and statistics, one
foreground plus at most one speculative decode on supported-memory machines,
and export priority. Settled pan/zoom must continue to reuse the corrected raster.

Look application must preserve the destination's film base, inversion IDs,
calibration, and geometry. Keep v1-to-v2 migration, lossless library backup,
unsupported-version rejection, no-op edits, and clipboard revision caching under
regression coverage. Saved tone versions 1–3 must retain their prior rendering;
editing a range or grading-level control promotes version 2/3 to version 4 in
one undo step, while version 1 requires the explicit Update Tone Controls action
and factory looks remain pinned to version 2. The standalone
CPU/Metal gate now includes current Film Bases, all factory recipes across
editable bases, public controls, combined grading, and version-4 tone cases
alongside the historical grid. Continue adding cases for new controls; synthetic
parity does not replace photographic or full-resolution acceptance.

Performance work requires a measured bottleneck, identical workload/quality in
before/after runs, physical-footprint reporting, and equivalence tests. Current
[export](../performance/40mp-export.md) and [analysis](../performance/preview-analysis.md)
evidence supplies regression baselines. The bounded
[full-resolution edit proxy](../performance/preview-scale-2026-09-14.md) is also
implemented and requires an exact final frame after every gesture. Measure the
current retained-preview/cache and concurrent-decode paths before using the dated
results as a present-day latency or memory claim. Completed
optimizations are not pending roadmap items. New profiling can justify another
bounded repair.

## Completed Source-Audit Repairs

The three September 20 follow-ups are now fixed and regression-tested:

- An uninitialized destination retains a pending copied look, resolves its film
  base on first decode, then applies the copied public controls. Saved Original
  frames retain their intentional base; relaunch and Undo/Redo preserve the intent.
- Rapid selection changes keep one render drain alive until its detached worker
  returns, reject the stale result, and consume the newest pending selection.
- **Load RAW Preview** remains available during inspect upgrades and requests
  full-sensor detail directly, cancelling inspect through the shared decoder gate.

Perspective now supports known frame proportions, a projective grid, visible
border framing, displacement-based corner drags, screen-distance snapping, and
one-source-pixel keyboard nudges. Reset Corners preserves the ratio in one undo
step. Existing automatic ratios and saved crops retain their prior behavior.

## Evidence-Driven Product Candidates

- Further preview tiling using an established interpolator, if profiling finds
  slow full-detail edits after retained-raster navigation and existing transient
  region rendering are accounted for.
- Applied dust removal, with representative masks and restoration quality.
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
