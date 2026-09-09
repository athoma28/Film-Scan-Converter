# Native macOS Product Roadmap

This is the ordered plan for remaining product work. Implemented capabilities
and dated validation belong in [development status](../development/native-macos.md);
user-facing behavior belongs in [Features](../features.md).

The product is a fast, flexible, trustworthy film-scanning workflow: import,
judge, adjust, transfer a look across a roll, and export predictable files.
New work must prevent incorrect results, improve that frequent workflow, close
a measured performance problem, or establish distribution evidence.

## Active Sequence

### 1. Verify Photographic Judgment In The Packaged App

Fit, 100%, pan, comparison, and manual-crop gesture mechanics have passed local
packaged checks. Automated viewport and geometry regressions also pass.
Remaining work is hands-on judgment across representative images:

- assess focus, grain, dust, fine tonal transitions, clipping, and color;
- inspect Original comparison and draft/inspect/full-resolution transitions;
- exercise crop, straighten, perspective, and their reset/undo behavior;
- confirm that the preview and reopened full-resolution result agree within
  the documented source-resolution and bit-depth boundaries.

Acceptance is a recorded photographic assessment and repairs for any concrete
workflow or image defect it exposes.

### 2. Validate A Realistic Roll And Real Repeated Captures

The automated three-frame RAW workflow covers look transfer, exceptions,
undo/redo, comparison, ordered export, decode reuse, and persisted settings.
A packaged stack check using duplicate JPEGs verifies mechanics only.

Use a real roll to establish an anchor look, apply it to selected frames,
correct outliers, inspect real Noise/HDR stacks, select outputs, and export.
Verify immediate visible changes, per-frame geometry/base preservation,
import order, one output per enabled stack, errors, and cancellation. Check
stack quality on independently captured images, including exposure brackets.
Add organization features only if this workflow demonstrates a need.

### 3. Prove Output And Distribution On An Independent Mac

Automated ImageIO/`sips` checks cover TIFF/JPEG/PNG color tags, bit depth,
dimensions, and orientation; DNG tests cover its processed-RGB tag contract.
Local app/ZIP assembly and validation work.

Remaining acceptance:

- judge exports in Preview/Photos and a suitable processed-DNG reader;
- assemble the final artifact from its release commit with green CI;
- Developer ID sign, notarize, staple, and pass Gatekeeper;
- install and launch on a supported Mac without Homebrew or the source checkout;
- repeat import/edit/compare/export/reopen, camera permission, settings,
  cancellation, collision, and relaunch checks;
- record the exact version/build, artifact hash, platform, and results.

The [release runbook](../development/native-release.md) owns the procedure.

## Standing Regression Requirements

Maintain deterministic CPU/export pixels and the frozen three-pass camera-scan
oracle. Preserve bounded latest-value-wins preview work, one authoritative RAW
export decode at a time, selected-file cache invalidation, safe cancellation,
collision handling, and cleanup. Geometry edits and comparison share coordinate
semantics; upstream geometry changes invalidate dependent canvas crops.

Performance work requires a measured bottleneck, identical workload/quality in
before/after runs, physical-footprint reporting, and equivalence tests. Current
[export](../performance/40mp-export.md) and [analysis](../performance/preview-analysis.md)
evidence supplies regression baselines; completed optimizations are not pending
roadmap items. New profiling can justify another bounded repair.

## Evidence-Driven Candidates After First Release

- Preview tiling using an established interpolator, if full-detail inspection
  remains slow under the current staged preview contract.
- Applied dust removal, with representative masks and restoration quality.
- Film-edge assistance, broader batch organization, or contact sheets when a
  real photographic workflow needs them.
- Calibration beyond one planar perspective warp, supported by repeatable
  geometric defects in real scans.
- Stage-based progress estimates that outperform current progress reporting.

## Parked: Stock And Capture Look Calibration

Existing Natural looks, Darkroom profiles, capture/stock/roll types, and offline
fitters remain supported. Further data preparation, named-stock fitting,
residual LUTs, halation simulation, stock classification, and ML are dormant.
Re-entry requires explicit owner direction, a concrete photographic question,
licensed representative pairs, held-out validation, and a bounded maintenance
budget. See [research scope](../film-processing-research.md).

## Outside The Current Plan

Novel X-Trans or learned demosaic, a three-pass Metal rewrite, live RawTherapee
float parity, speculative full-resolution RAW prefetch, unmeasured writer
replacement, vendor tethering without hardware/demand, and expansion of the
Python product are outside the plan.

[Python retirement](../legacy-python.md) follows supported-workflow replacement
and distribution proof; it does not gate a sound native release.
