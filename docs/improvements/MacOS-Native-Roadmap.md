# Native macOS Product Roadmap

This roadmap orders work by photographer value and release risk. It is not a
history of the Swift port, and it does not require every technically
interesting idea to be built.

For verified current behavior, tests, and limitations, use
[Native macOS Development Status](../development/native-macos.md). Detailed
measurements live in the
[40 MP benchmark notes](../performance/40mp-export.md). Processing research is
background material, not a competing delivery plan.

## Current Product Direction

The active goal is a fast, flexible, trustworthy film-scanning workflow—not a
large film-stock-learning project.

Film Scan Converter should help a photographer:

1. import a roll and get a pleasing, workable inversion quickly;
2. judge focus, grain, color, clipping, crop, and dust confidently;
3. make broad corrections without being forced into a named-stock model;
4. carry a look across a roll while keeping exceptions easy;
5. export predictable files without risking sources, partial outputs, or
   runaway memory.

Stock/capture fitting remains documented and its small deterministic
infrastructure stays in the repository, but further dataset preparation,
stock-look fitting, named stock presets, residual LUT work, or ML experiments
are explicitly paused until the project owner asks to resume them. A small
collection of roughly eight stocks—some discontinued—is useful for spot checks,
but does not justify making stock-learning an active product track.

## Product Standard

A high-quality first public release must:

- preserve source files and never present a misleading partial output;
- show useful corrected pixels quickly and keep interaction fluid;
- let photographers inspect the image at meaningful detail;
- make corrections reversible and keep geometry non-destructive;
- make roll-level consistency fast without blocking per-frame exceptions;
- keep large RAW browsing and export memory-bounded;
- produce stable, reopenable files with explicit color and format semantics;
- recover cleanly from cancellation, invalid input, corrupt settings, and
  unwritable destinations;
- install and launch as a normal notarized macOS application without requiring
  development tools or Homebrew.

Compatibility, performance, and architecture support those outcomes; they are
not substitutes for them.

## Priority Test

Work belongs in the active sequence only when it does at least one of the
following:

1. prevents data loss, crashes, wrong pixels, misleading previews, or
   misleading output;
2. materially improves the frequent judge-adjust-sync-export loop;
3. closes a measured latency or memory problem;
4. proves the distributed artifact on a supported user machine;
5. supplies evidence required to make one of those decisions.

Scientific novelty, theoretical stock fidelity, or a larger control surface is
not enough by itself. New controls should earn their place through a common
photographic need and remain progressively disclosed when they are specialized.

## Active Sequence

### 0. Close The Bounded Performance Measurement — Completed 2026-07-15

The 40 MP cycle is closed and returns to a standing regression contract rather
than remaining an open-ended optimization track.

Completed evidence includes:

- repeated TIFF/JPEG/PNG/DNG export baselines with hashes and per-run cleanup;
- a ten-file engine export with no sustained physical-footprint growth;
- compact parallel RGB packing for every writer with identical output hashes;
- release-mode first-paint, cached/uncached switching, rapid-selection, and
  preview-cache-depth measurements with no new interactive bottleneck;
- a ten-job app-path TIFF sequence over six unique RAFs plus four duplicate
  queue additions, with 22.57/22.80-second per-job p50/p95, a 71.03–74.14 MB
  observed physical-footprint band, 61.41 MB after model release, and all ten
  temporary outputs removed;
- active-decode cancellation measured at 21.57 seconds from request to the next
  safe boundary, with no output written and 59.62 MB after model release.

Acceptance:

- one full-resolution RAW export at a time;
- no sustained per-file physical-footprint growth;
- no output, metadata, or demosaic-quality regression;
- measured artifacts continue to be removed after each run.

Optimize again only when profiling exposes a user-visible latency or
resource-safety problem.

### 1. Make The Still Preview A Reliable Judging Surface — Active

Implement zoom and pan before adding more processing ideas. A photographer must
be able to inspect focus, grain, dust, crop edges, and fine tonal transitions,
not merely see a fit-to-window composition.

Deliver:

1. fit, zoom-in/out, and 100% commands with normal Mac trackpad/mouse behavior;
2. smooth panning that does not fight crop, straighten, perspective, or loupe
   interactions;
3. original/corrected comparison at the same viewport and magnification;
4. clear preview-source status so an embedded RAW thumbnail is never mistaken
   for full-resolution export evidence;
5. stable clipping diagnostics while navigating the image.

Acceptance:

- zoom/pan remains responsive on the bounded preview path;
- browsing and lookahead never start speculative full-resolution RAW decodes;
- **Load RAW Preview** remains the explicit higher-quality preview action;
- selection changes and resets leave the viewport in a predictable state;
- preview/export geometry remains shared and pixel dimensions remain truthful.

### 2. Make Editing Safely Reversible

Add native undo/redo for the adjustments photographers actually make.

Deliver:

1. undo/redo for tone, color, inversion, crop, straighten, perspective,
   rotation, flip, frame, and profile/preset application;
2. slider-drag coalescing so one gesture is one understandable history step;
3. clear history boundaries per file, with no undo state leaking across
   selection changes;
4. compatibility with preset removal, reset, copy/paste, and persisted
   per-file settings.

Acceptance:

- every visible edit can be reversed and reapplied without pixel or geometry
  drift;
- undo never changes source files or another scan's state;
- relaunch behavior remains explicit: saved current state is restored, while
  transient undo history need not be.

### 3. Tune The Roll And Batch Workflow

Run a realistic photographer workflow rather than designing batch features in
isolation: import a roll, establish an anchor look, apply it, correct outliers,
select intended frames, and export them.

Expected first improvement:

- add **Apply Look to Selected** alongside the existing explicit
  **Apply Settings to All Open Files**, preserving each frame's crop, orientation,
  perspective, and measured film base.

The usability pass must also verify:

- rapid next/previous and multi-selection review;
- immediate visible preset/copy/paste/apply results;
- clear edited, preview-ready, selected, active-export, and pending-export
  states;
- easy per-frame exceptions after a roll-wide look;
- import-ordered Export Selected and duplicate-friendly queue behavior.

Only promote sidebar reordering, a larger export queue, ratings, or other
organization features if this real workflow demonstrates the need.

### 4. Prove Output Trust And Color Semantics — Beta Contract Implemented

Exercise the actual packaged app, not only engine entry points.

Deliver:

- representative standard-image and RAW import;
- corrected-preview orientation matching reopened full-resolution export;
- power-law, density/flat-field, crop/straighten/perspective, preset, batch,
  and relaunch workflows;
- TIFF, JPEG, PNG, and processed-RGB DNG export and reopen;
- cancellation, collisions, corrupt settings, invalid input, unwritable
  destinations, and partial-output cleanup;
- reproduction of the originally reported PNG source/destination case;
- preserve the implemented named-sRGB profile contract for TIFF/JPEG/PNG and
  the output-referred linear-sRGB metadata contract for processed DNG.

Prefer a small legally distributable committed corpus for CI. Keep larger or
restricted local corpora as clearly reported supplemental validation.

The format writers, structural tests, and archive-level packaging contract are
complete for beta. Broader representative-camera and independent-viewer
reopening remains part of the path from technical beta to the high-quality
first-release standard.

Acceptance:

- reopened outputs match the intended preview within the documented preview
  source and bit-depth boundary;
- every output format carries honest dimensions, depth, metadata, and color
  interpretation;
- no failed job leaves a file that appears successful.

### 5. Complete Distribution Proof

After the editing and output contracts stabilize:

1. produce the final self-contained app and ZIP;
2. run the full native suite and packaged-app smoke matrix;
3. Developer ID sign, notarize, staple, and pass Gatekeeper;
4. install on a supported clean Mac without Homebrew or the source checkout;
5. repeat import, edit, compare, batch, export, reopen, camera-permission,
   settings, preset, and relaunch checks;
6. record hardware, macOS, version/build, signing identity, notarization ID,
   and results in release notes.

## First-Release Gates At A Glance

1. Closed: app-path ten-file performance, memory, and cancellation measurement.
2. Zoom/pan makes the preview useful for photographic inspection.
3. Editing-state changes have reliable undo/redo.
4. A real roll workflow validates anchor-look, selected/all application,
   per-frame exceptions, selection, and export.
5. Packaged outputs pass correctness, color-space, reopen, failure, and cleanup
   checks.
6. The signed/notarized app passes Gatekeeper and clean-machine use.

Do not delay these gates for stock-specific calibration, speculative
processing models, or a larger advanced-control surface.

## Evidence-Driven Candidates After First Release

These are ordered by likely photographic value, but each still needs real use
evidence:

1. **Applied dust removal** when representative scans demonstrate safe masks,
   acceptable restoration, and an explicit preview/enable contract.
2. **Film-frame edge assistance** when holder/rebate fixtures can provide a
   visible starting quadrilateral without overriding manual reticles.
3. **Broader batch organization**—sidebar reordering, ratings, or a fuller
   export queue—when roll workflows outgrow import order and current selection.
4. **Proofing and contact sheets** when photographers identify a concrete
   review, client, or darkroom-style selection workflow.
5. **Geometric calibration beyond one planar perspective warp** when real scans
   show repeatable lens distortion or film-plane/sensor-plane misalignment.
6. **Progress estimates** when measured stage histories can outperform the
   current honest determinate/indeterminate reporting.

## Parked: Stock And Capture Look Calibration

This track is intentionally dormant until the project owner explicitly
reactivates it.

Preserve:

- generic inversion, film-base, density, roll/capture profile, manual
  dye-crossover, and profile persistence already useful to photographers;
- the small offline density-matrix fitter and its synthetic tests;
- research notes describing how serious held-out calibration would work.

Do not spend active roadmap time on:

- collecting, aligning, labeling, or cleaning a stock-reference corpus;
- fitting or tuning named stock looks from the currently small library;
- stock classification, learned models, ML training, or look embeddings;
- digitizing per-stock characteristic curves;
- residual 3D LUT generation or stock-specific halation simulation;
- shipping profiles named after current or discontinued stocks without measured
  validation.

Re-entry requires all of the following:

1. the project owner explicitly asks to resume the track;
2. a concrete photographic question that generic controls cannot answer;
3. enough licensed, representative paired data for frame-level held-out tests;
4. a bounded time/maintenance budget and an acceptance metric tied to visible
   photographer value.

The existence of fitting code or research notes is not itself a reason to
resume.

## Not Currently Planned

- deep-learning or large-scale stock-look training;
- exhaustive reproduction of every Python intermediate and parameter;
- arbitrary “3×/5× faster than Python” targets across incompatible stages;
- replacing measured code with Metal or Accelerate solely for architecture;
- GPU perspective warp or dust inpainting before profiling shows a problem;
- exact RawTherapee denoise/sharpen ports without photographic evidence;
- persistent unfinished export jobs before security-scoped destination
  ownership is defined;
- vendor-specific tethering SDK work without supported hardware and demand;
- a searchable shortcut overlay before the real command set warrants it;
- archiving Python merely to make the repository look complete.

Any non-parked item can return with evidence that changes its priority. The
stock/capture calibration track additionally requires explicit owner direction.

## Completed Foundation

Maintain this foundation rather than repeatedly replanning it:

- native standard-image and LibRaw-backed RAW decoding;
- frozen compatibility fixtures and deterministic native CPU contracts;
- automatic frame detection, straighten, manual crop, four-corner perspective,
  loupe, alignment assistance, rotation, flip, frame, and aspect ratio;
- power-law color-negative inversion and an optional capture-aware density path;
- generic dye-crossover, protected semantic color/tone controls, curves, color
  wheels, clipping diagnostics, and a reference-derived adaptive look;
- bounded latest-value-wins GPU preview with CPU/GPU regression coverage;
- per-file settings, presets, clipboard transfer, apply-to-all, edit markers,
  multi-selection, and adjustable preview lookahead;
- collision-safe TIFF/JPEG/PNG/processed-RGB-DNG individual and sequential
  batch export with cancellation, cleanup, progress, and per-file errors;
- native dust candidate detection and aligned diagnostic overlay;
- self-contained local app/ZIP assembly and archive validation;
- staged RAW/export benchmarks and app-path signposts.

Detailed implementation claims belong in [Features](../features.md), not here.

## Python Retirement

Python retirement is repository cleanup, not a product phase. It follows user
workflow replacement and release proof. Dust removal may remain a documented
legacy-only workflow after the first native release; do not delay a sound
native release solely to claim complete Python replacement. See
[Legacy Python Application](../legacy-python.md).

## Roadmap Maintenance

- Keep only one ordered plan: this page.
- Keep current facts and evidence in the native status page.
- Keep benchmark numbers in performance documents.
- Keep user-visible claims in Features.
- Keep color-science and calibration research as reference material unless the
  parked track is explicitly reactivated.
- Move completed items to the short foundation summary.
- When priorities change, record the reason and acceptance condition rather
  than creating another speculative phase tree.
