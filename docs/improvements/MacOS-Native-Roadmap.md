# Native macOS Product Roadmap

This roadmap orders work by photographer value and release risk. It is not a
history of the Swift port, and it does not require every technically
interesting idea to be built.

For verified current behavior, tests, and limitations, use
[Native macOS Development Status](../development/native-macos.md). Detailed
measurements live in the
[40 MP benchmark notes](../performance/40mp-export.md). The audited
[full-resolution performance guide](../../PERFORMANCE-OPPORTUNITIES-2026-07-27.md)
records the evidence, rejected shortcuts, and implementation handoff for the
completed full-resolution export-latency slice. The next performance work is
the bounded inspect/re-export slice below, not a continuation of that rewrite.
Processing research is background material, not a competing delivery plan.

## Current Product Direction

The active goal is a fast, flexible, trustworthy film-scanning workflow that a
RawTherapee-style user can open and judge without waiting on final-quality CFA
work. It is a home side project. It is not a large film-stock-learning project,
and it is not new image-quality frontier research.

Known techniques, already-measured seams, and preview/export splits are in
scope. A new X-Trans interpolator, a Metal port of three-pass Markesteijn, a
live RawTherapee float demosaic, or any other “match Adobe at 100% with novel
CFA math” effort is out of scope.

Film Scan Converter should help a photographer:

1. import a roll and get a pleasing, workable inversion quickly;
2. judge focus, grain, color, clipping, crop, and dust confidently;
3. make broad corrections without being forced into a named-stock model;
4. carry a look across a roll while keeping exceptions easy;
5. export predictable files without risking sources, partial outputs, or
   runaway memory.

Export pixels stay on the frozen camera-scan oracle (LibRaw 0.21.4 integer
three-pass, same-machine SHA-256) until the owner explicitly replaces that
lock. That oracle is a decoder regression harness, not a claim of live
RawTherapee parity. Interactive preview is already allowed to differ (embedded
JPEG, 1-pass, 2/255 GPU). Determinism—same app version, same settings, same
bytes—remains a product promise.

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

That cycle’s “optimize again only when profiling exposes a problem” gate was
met: remaining user-visible waits are Load RAW Preview (full-sensor 1-pass
then downscale) and every RAW export re-decoding from scratch. Item 5 owns
those seams. Do not reopen item 1 as an unrestricted demosaic rewrite.

### 1. Resolve Measured Full-Resolution RAW Export Bottlenecks — Completed 2026-08-12

The bounded 40 MP cycle established a trustworthy baseline rather than proving
that roughly 20 seconds of three-pass X-Trans demosaic is acceptable forever.
The 2026-07-27 follow-up audit supplied new measured evidence: an isolated
LibRaw 0.21.4 build with forced OpenMP reduced one Fuji processed-DNG workload
from 14.74 to 2.10 seconds and demosaic from 13.18 to 1.38 seconds. The
multi-threaded outputs were not repeatable, so this result is an opportunity
bound—not a production candidate or a release claim.

Work in this order:

1. add camera-scan stage-boundary hashes and repeated determinism mode to
   `FilmScanExportBenchmark` — completed 2026-07-28: opt-in SHA-256 capture at
   eight pipeline boundaries, a `--determinism` repeat mode with per-boundary
   agreement, engine tests covering the contract, and a passing
   five-repetition stock-build baseline recorded in the 40 MP benchmark notes;
2. add a full-resolution X-Trans camera-scan fixture — completed 2026-07-28:
   `camera_scan_decode_reference.json` pins the `DSCF2833.RAF` image shape,
   color description, mosaic metadata, and the five decode-stage digests from
   the determinism baseline, and `CameraScanByteIdentityTests` proves the
   final-quality three-pass decode reproduces every stage digest plus the
   Swift pixel hash byte-for-byte (debug and release agree on this machine);
3. isolate the first nondeterministic boundary in LibRaw's existing threaded
   unpack/X-Trans path — completed 2026-07-30: a pinned forced-OpenMP LibRaw
   0.21.4 build was swept at 1, 2, 4, 8, 10, and 14 threads with five
   repetitions each; the unpacked mosaic remained byte-identical to the stock
   reference at every count, while the first changed boundary was always
   `demosaicedImage`; 8, 10, and 14 threads were also non-repeatable, so that
   overlapping-tile threaded decoder was not enabled in production;
4. add neutral, tone, protected-color, dye-mixing, and combined-adjustment
   full-resolution correction scenarios, including physical footprint —
   completed 2026-08-03: `FilmScanExportBenchmark --corrections` produced a
   three-repetition 40.19 MP release matrix, all corrected/output hashes
   repeated exactly, all 15 TIFFs were removed, corrected-stage medians ranged
   from 0.105 seconds (neutral) to 2.749 seconds (combined), post-scenario
   physical footprint stayed within 47.3–54.2 MB, and the adjusted paths raised
   the process-lifetime peak to 1.984 GB; the five corrected-image hashes now
   anchor a committed full-resolution byte-identity fixture;
5. after evidence exists, fix the responsible RAW stage and reduce adjusted
   correction allocations/passes before considering writer or batch work —
   both repairs are complete (2026-08-12). Tone, protected-color, and
   dye-mixing run in-place and in parallel, the adjusted-scenario
   process-lifetime peak fell from 1.984 GB to 1.017 GB, and the committed
   correction-scenario digests reproduce byte-for-byte. X-Trans keeps LibRaw's
   serial work inside each tile and the overlapping-tile dependence chain,
   then runs independent `2*row+col` wavefront diagonals. Five eight-worker
   runs reproduced every approved digest; the 2026-08-13 wavefront follow-up
   reduced warm demosaic from 3.38–3.54 seconds to 2.85–2.86 seconds versus
   the 12.72–12.77-second stock baseline.

Do not start by porting RawTherapee X-Trans, running dependent X-Trans passes
concurrently, reducing final-quality passes, replacing scalar `pow` in
isolation, or prefetching another authoritative RAW. TIFF/PNG writer changes
remain conditional on selected-compression usage. Bayer RCD work requires a
committed Bayer fixture and decomposed timing first.

Acceptance:

- final-quality three-pass camera-scan pixels are deterministic across at least
  five repeated parallel runs and preserve the approved exact-output contract;
- a numeric-tolerance alternative requires an explicit product decision,
  documented rounding policy, and visual qualification;
- every claimed speedup compares the same file, settings, stage set, quality,
  release build, and worker count with at least three timed repetitions;
- physical footprint remains bounded, cancellation and cleanup remain correct,
  and one authoritative full-resolution RAW remains in flight;
- a custom LibRaw build, if adopted, passes dependency closure, notices,
  packaged launch, and clean-Mac validation;
- the detailed commands and results are added to the 40 MP benchmark notes.

The audited performance guide owns the technical sequence. This roadmap owns
its product priority; it is not permission for an open-ended rewrite.

The closing matrix covered 18 repeated format outputs, ten sequential engine
TIFFs, and the ten-job app path plus active-decode cancellation. Every output
scheduled for cleanup was removed, the engine's post-release footprint stayed
within 45.5–53.6 MB with a 686.8 MB peak, and cancellation left no output.

### 2. Make The Still Preview A Reliable Judging Surface — Implementation Complete; Direct Check Pending

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

### 3. Make Editing Safely Reversible — Completed 2026-07-26

Native undo/redo now covers the adjustments photographers actually make.

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

### 4. Tune The Roll And Batch Workflow — Implementation Complete; Verify In Use

Run a realistic photographer workflow rather than designing batch features in
isolation: import a roll, establish an anchor look, apply it, correct outliers,
select intended frames, and export them.

Improvements implemented:

- **Apply Look to Selected** now sits alongside the existing explicit
  **Apply Settings to All Open Files**, preserving each frame's crop, orientation,
  perspective, and measured film base.
- **Previous Scan** / **Next Scan** follow import order, collapse a
  multi-selection to the adjacent file, and fit the new preview. Option-Command-Up
  and Option-Command-Down remain available while the inspector has focus.
- Sidebar rows show edited, preview-ready, active-export, and pending-export
  states in addition to native selection highlighting.
- Conservative repeated-capture proposals now appear for adjacent, same-size
  imports. Opt-in translation-only stacking supports Auto, Noise, and HDR
  modes, with preview and full-resolution export rebuilt from the captures.

The usability pass must also verify:

- multi-selection review still feels immediate;
- immediate visible preset/copy/paste/apply results;
- easy per-frame exceptions after a roll-wide look;
- import-ordered Export Selected and duplicate-friendly queue behavior;
- stack preview/export behavior on a realistic roll, including the one-output
  anchor-name rule and the flat-field restriction.

Only promote sidebar reordering, a larger export queue, ratings, or other
organization features if this real workflow demonstrates the need.

Verify the remaining usability items while exercising item 5 on a real roll.
Do not insert a separate organization-features phase before the feel slice.

### 5. Make Open, Inspect, And Re-Export Feel Fast — Next

Use known techniques to remove the waits a RawTherapee-style user still hits
after the completed three-pass wavefront work. Do not invent a new demosaic.
Do not change export pixels.

The interactive path already shows an embedded JPEG in tens of milliseconds
and applies settings on the GPU in a few milliseconds. The remaining feels-slow
seams are:

- **Load RAW Preview** still unpacks the RAF and runs 1-pass X-Trans at full
  sensor size, then downscales to 2400px;
- every RAW export calls a fresh full-resolution three-pass decode and discards
  the buffer.

Fuji compressed unpack is no longer serial. Independent strips run across at
most eight workers through LibRaw's `fuji_decode_loop` hook, with a locking
datastream wrapper for seek+read. `LIBRAW_FORCE_OPENMP` stays off.

Work in this order, as small slices:

1. **Parallel Fuji unpack without enabling LibRaw’s racy X-Trans tiles.** —
   completed 2026-08-14: camera-scan overrides `fuji_decode_loop` with GCD
   over independent compressed strips, installs a mutex on LibRaw's existing
   `lock()`/`unlock()` I/O seam, and leaves overlapping-tile X-Trans OpenMP
   disabled. Five release repetitions reproduced every approved digest;
   same-session unpack fell from a 1.335-second serial median to 0.266 seconds
   at eight workers. `FSC_UNPACK_WORKERS=1` remains the serial mosaic oracle.
2. **Demosaic Load RAW Preview at the preview bound.** Interpolate at most
   2400px of work, using the existing 1-pass camera-scan interpolator or
   another already-shipped path—not a new CFA algorithm. Browsing stays on the
   embedded JPEG. The source badge stays honest. Export stays three-pass full
   resolution. Metal is allowed here only if preview-sized CPU work is still
   too slow; it is not a three-pass Markesteijn port.
3. **Retain the last full-resolution decode for the selected file.**
   Settings-only re-export of that file skips CFA work. Drop the buffer on
   selection change, reset, and teardown. Keep one authoritative full-resolution
   RAW in flight. This is not prefetch of file N+1 and not a roll-sized decode
   cache. Budget about 241 MB of 16-bit RGB for a 40 MP frame.

Stop after each slice if the photographer-visible wait is gone. Do not continue
into 100% viewport tiling, writer replacement, or two-file decode overlap as
part of this item.

Acceptance:

- Load RAW Preview no longer interpolates the full 40 MP mosaic as a means of
  producing a 2400px display source;
- a settings-only re-export of the current RAW does not repeat unpack+demosaic;
- the camera-scan three-pass fixture still reproduces every approved digest;
- physical footprint stays bounded; cancellation still writes no output;
- each claimed speedup uses the same file, settings, quality, and release
  build with at least three timed repetitions, recorded in the 40 MP notes.

Out of this item:

- a new X-Trans interpolator, learned demosaic, or “beat Adobe at 100%”;
- Metal or Accelerate ports of three-pass Markesteijn;
- porting current RawTherapee float X-Trans;
- accepting numeric tolerance on export pixels;
- two authoritative full-resolution RAWs in flight;
- speculative full-resolution decode of the next file or the whole roll.

### 6. Prove Output Trust And Color Semantics — Beta Contract Implemented

Exercise the actual packaged app, not only engine entry points.

Deliver:

- representative standard-image and RAW import;
- corrected-preview orientation matching reopened full-resolution export;
- default calibrated inversion, legacy power-law, density/flat-field,
  crop/straighten/perspective, preset, batch, and relaunch workflows;
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

### 7. Complete Distribution Proof

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

1. Closed: the measured RAW-threading and adjusted-correction follow-up
   preserves deterministic final-quality pixels, bounded physical footprint,
   cancellation, cleanup, and packaged dependency closure.
2. Zoom/pan makes the preview useful for photographic inspection.
3. Closed: editing-state changes have reliable per-file undo/redo with
   gesture coalescing and transient relaunch semantics.
4. A real roll workflow validates anchor-look, selected/all application,
   per-frame exceptions, selection, and export.
5. Open, inspect, and settings-only re-export no longer wait on a full-sensor
   1-pass or a repeated three-pass decode. Export pixels stay on the frozen
   camera-scan oracle.
6. Packaged outputs pass correctness, color-space, reopen, failure, and cleanup
   checks.
7. The signed/notarized app passes Gatekeeper and clean-machine use.

Do not delay these gates for stock-specific calibration, a new demosaic, or a
larger advanced-control surface. Do not delay notarization for 100% viewport
tiling or writer replacement.

## Evidence-Driven Candidates After First Release

These are ordered by likely photographic value, but each still needs real use
evidence:

1. **Viewport-tiled 100% preview demosaic** using an already-known interpolator
   (preview 1-pass or equivalent), only if inspecting grain at 100% is still
   slow after item 5. This is tiling and caching, not a new CFA algorithm.
2. **Applied dust removal** when representative scans demonstrate safe masks,
   acceptable restoration, and an explicit preview/enable contract.
3. **Film-frame edge assistance** when holder/rebate fixtures can provide a
   visible starting quadrilateral without overriding manual reticles.
4. **Broader batch organization**—sidebar reordering, ratings, or a fuller
   export queue—when roll workflows outgrow import order and current selection.
5. **Proofing and contact sheets** when photographers identify a concrete
   review, client, or darkroom-style selection workflow.
6. **Geometric calibration beyond one planar perspective warp** when real scans
   show repeatable lens distortion or film-plane/sensor-plane misalignment.
7. **Progress estimates** when measured stage histories can outperform the
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

- new image-quality frontier research: novel X-Trans interpolators, learned
  demosaic, or “match Adobe/Capture One at 100%” CFA work;
- Metal or Accelerate ports of three-pass Markesteijn, or porting current
  RawTherapee float X-Trans, in order to keep or chase export identity;
- replacing measured code with Metal or Accelerate solely for architecture;
- two authoritative full-resolution RAWs in flight, or prefetch of file N+1;
- deep-learning or large-scale stock-look training;
- exhaustive reproduction of every Python intermediate and parameter;
- arbitrary “3×/5× faster than Python” targets across incompatible stages;
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
- paired-scan-calibrated color and B&W inversion, legacy power-law presets,
  named stock alternates, and an optional capture-aware density path;
- generic dye-crossover, protected semantic color/tone controls, curves, color
  wheels, clipping diagnostics, and a reference-derived adaptive look;
- bounded latest-value-wins GPU preview with CPU/GPU regression coverage;
- per-file settings, presets, clipboard transfer, apply-to-selected/all,
  import-ordered previous/next, edited/preview-ready/export markers,
  multi-selection, and adjustable preview lookahead;
- per-file, session-local undo/redo with gesture coalescing, standard Mac
  commands, persisted current state, and exact parameter restoration;
- collision-safe TIFF/JPEG/PNG/processed-RGB-DNG individual and sequential
  batch export with cancellation, cleanup, progress, and per-file errors;
- native dust candidate detection and aligned diagnostic overlay;
- self-contained local app/ZIP assembly and archive validation;
- staged RAW/export benchmarks, camera-scan byte-identity fixtures, and
  app-path signposts;
- deterministic parallel X-Trans wavefront demosaic and parallel Fuji
  compressed unpack, both gated by the frozen camera-scan oracle.

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
