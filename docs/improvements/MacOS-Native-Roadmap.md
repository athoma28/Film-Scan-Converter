# Native macOS Product Roadmap

This roadmap orders work by product risk and user value. It is not a history of
the Swift port and it does not require every technically interesting idea to be
built.

For verified current behavior, test evidence, and limitations, use
[Native macOS Development Status](../development/native-macos.md). Detailed
performance measurements live in the
[40 MP benchmark notes](../performance/40mp-export.md). Historical design and
research documents are supporting evidence, not competing roadmaps.

## Product Standard

A high-quality first public release must:

- preserve the user's source files and never leave a misleading partial output;
- make common import, correction, comparison, and export work obvious and
  reversible;
- show useful corrected pixels quickly while authoritative work continues;
- keep large RAW batches memory-bounded;
- produce stable, reopenable outputs with honest format semantics;
- recover cleanly from cancellation, invalid input, corrupt settings, and
  unwritable destinations;
- install and launch as a normal notarized macOS application without requiring
  development tools or Homebrew.

Compatibility, performance, and architectural elegance support those outcomes;
they are not substitutes for them.

## Priority Model

Work belongs in the active plan only when it does at least one of the following:

1. prevents data loss, crashes, incorrect pixels, or misleading output;
2. completes a frequent editing or batch workflow;
3. closes a measured latency or memory problem;
4. proves the distributed artifact on a supported user machine;
5. supplies evidence needed to make one of those decisions.

Ideas without that evidence remain candidates, not commitments.

## Now: Close The Measurement Slice

Finish the already-started 40 MP measurement cycle without broadening it into a
general optimization phase.

Completed evidence:

1. Three TIFF/JPEG/PNG/DNG repetitions for `DSCF0669.RAF`, followed by three
   TIFF repetitions for `DSCF0718.RAF` and `DSCF0729.RAF`, with per-sample,
   median, and nearest-rank p95 stages. Every generated export was hashed and
   removed immediately.
2. The corrected ten-file TIFF confirmation closes the engine memory gate:
   post-release physical footprint fell from 52.74 MB to 42.78 MB and peak
   physical footprint stayed at 686.11 MB. Rising resident bytes were
   classified as reclaimable reusable/empty allocator regions, not retained
   live image data.
3. TIFF packing now uses a compact 48-bit RGB buffer. It removes 80.37 MB from
   the 40.19 MP writer intermediate, reduced the ten-file median packing
   interval from 29.73 ms to 22.88 ms (23.0%), and preserved all ten output byte
   counts and SHA-256 hashes.

Remaining deliverables:

1. p50/p95 first corrected pixels, authoritative replacement, cached/uncached
   switching, and rapid-selection drain;
2. an app-path ten-file sequential export result including cancellation latency
   and post-run physical footprint;
3. no further engine optimization in this cycle unless those remaining
   measurements expose another dominant, safely output-preserving seam.

Acceptance:

- no output-contract or metadata regression;
- one full-resolution RAW export at a time;
- no sustained per-file physical-footprint growth;
- no quality-reducing replacement for three-pass X-Trans demosaic;
- benchmark outputs continue to be removed after each measured run.

## Before First Public Release

### 1. Representative Packaged-App Correctness

Build a release-candidate matrix around the actual app path:

- standard image plus representative RAW import;
- provisional-to-authoritative replacement with stable orientation;
- default power-law and density/flat-field processing;
- automatic frame detection, interactive crop/straighten adjustment,
  perspective crop, frame, presets, copy/paste, and relaunch restoration;
- TIFF, JPEG, PNG, and processed-RGB DNG export and reopen;
- cancellation, collisions, corrupt settings, invalid input, unwritable
  destinations, and partial-output cleanup;
- original reported PNG source/destination reproduction.

Prefer a small legally distributable committed corpus for CI. Keep larger or
restricted local corpora as explicit supplemental validation rather than tests
that appear green when they did not run.

### 2. Essential Editing Workflow

Implement and validate, in this order:

1. undo/redo for editing-state changes;
2. zoom and pan in the still preview;
3. ordered sidebar multi-selection and lazy Export Selected;
4. a real batch-editing usability pass and fixes found by it.

The current Original toggle is adequate unless testing demonstrates that a
split view is needed. Sidebar drag reordering becomes a release requirement
only if users cannot reliably preserve intended scan order without it.

### 3. Release Candidate And Distribution

After correctness and essential workflow changes stabilize:

1. produce the final self-contained app and ZIP;
2. run the full native suite and packaged-app smoke matrix;
3. Developer ID sign, notarize, staple, and pass Gatekeeper;
4. install on a supported clean Mac without Homebrew or the source checkout;
5. repeat import, edit, all-format export, reopen, camera-permission, settings,
   preset, and relaunch checks;
6. record hardware, macOS, version/build, signing identity, notarization ID, and
   results in release notes.

## After First Public Release

These are reasonable candidates, ordered by likely product value, but require
usage evidence before implementation:

1. **Sidebar reordering and broader batch organization** if real rolls require
   more than ordered import and multi-selection.
2. **A fuller in-process export queue** if users routinely combine individual,
   selected, and all-file jobs while an export is active. Keep execution
   sequential for RAW memory bounds.
3. **Dust removal** if users need native replacement of the Python workflow and
   representative scans demonstrate safe masks and acceptable restoration.
   Ship it with an explicit preview/enable control; never infer that detected
   candidates should be destructively removed.
4. **Stock/capture calibration** when held-out measured data can validate
   per-stock curves, matrices, or residual LUTs. Do not add profile complexity
   based only on theoretical completeness.
5. **Geometric calibration beyond a single perspective crop** when real scans
   show repeatable lens distortion or film-plane/sensor-plane non-alignment
   that a crop/straighten perspective warp cannot correct. This needs
   representative fixtures and a preview/export parity contract before UI
   exposure.
6. **Progress estimates** only after measured stage histories are stable enough
   to outperform honest determinate/indeterminate progress.
7. **Contact sheets** only when requested by a concrete review or proofing
   workflow.

## Not Currently Planned

The following are intentionally not active commitments:

- exhaustive reproduction of every Python intermediate and parameter
  combination;
- exact OpenCV contour results for every integer rotation angle;
- arbitrary “3×/5× faster than Python” gates when stage sets differ;
- replacing measured code with Metal or Accelerate solely because an old phase
  called for it;
- histogram equalization without a connected preview/export workflow;
- porting CPU fallback paths to GPU solely for compatibility. The normal
  interactive MacBook Pro development target is GPU-first, but CPU remains the
  deterministic correctness and fallback path;
- GPU perspective-warp or dust-inpainting targets before profiling or real
  workflow testing shows a user-visible problem;
- exact RawTherapee denoise/sharpen kernel ports without held-out photographic
  evidence that the current bounded native policy is inadequate;
- direct camera-to-Rec.2020 conversion without a validated color-management
  plan and test corpus;
- persistent unfinished export jobs before security-scoped destination bookmark
  ownership is defined;
- vendor-specific tethering SDK work without a supported camera and explicit
  product demand;
- a searchable keyboard-shortcut overlay before the actual command set becomes
  difficult to discover through normal macOS menus;
- archiving Python merely to make the repository look complete.

Any item can return to the roadmap with evidence that changes its priority.

## Completed Foundation

The following foundation exists and should be maintained rather than repeatedly
replanned:

- native standard-image and LibRaw-backed RAW decoding;
- frozen compatibility fixtures plus deterministic native CPU contracts;
- automatic frame detection, a two-click horizontal/vertical straighten guide,
  a post-straighten drag-box crop with full-resolution output dimensions,
  direct four-corner crop handles, a visible alignment grid, persisted planar
  perspective correction, rotation, flip, frame, and aspect ratio;
- RawTherapee-compatible power-law film-negative inversion and an optional
  capture-aware density path;
- protected semantic color/tone controls, curves, and three-way color wheels;
- bounded Core Image/Metal still preview with CPU/GPU regression coverage;
- per-file settings, presets, clipboard transfer, apply-to-all, edit markers,
  and adjustable lookahead caching;
- TIFF/JPEG/PNG/processed-RGB-DNG individual and memory-bounded batch export;
- collision-safe destinations, stage-boundary cancellation, complete cancelled-
  item accounting, partial cleanup, progress, and per-file errors;
- native dust candidate detection and aligned diagnostic overlay;
- self-contained local app/ZIP assembly and archive validation;
- staged RAW/export benchmarks and app-path signposts.

Detailed implementation claims belong in [Features](../features.md) and
[Native Development Status](../development/native-macos.md), not here.

## Python Retirement

Python retirement is repository cleanup, not a product phase. It follows user
workflow replacement and release proof. The current gates are maintained in
[Legacy Python Application](../legacy-python.md).

Dust removal may remain a supported legacy-only workflow after the first native
release. That is acceptable if it is documented honestly. Do not delay a sound
native release solely to claim complete Python replacement.

## Roadmap Maintenance

- Keep only one ordered plan: this page.
- Keep current facts and evidence in the native status page.
- Keep benchmark numbers in performance documents.
- Keep user-visible claims in Features.
- Move completed items to the short foundation summary rather than leaving them
  numbered among pending work.
- When priorities change, record the reason and the acceptance condition, not a
  new speculative phase tree.
