# Real-Time Still Preview Plan

**Status:** Completed through Stage 3; Stage 4 deferred

**Last updated:** 2026-06-15

## Current Progress

- Stage 0 live slider bindings are implemented; slider getters now read the
  current model parameters throughout a drag.
- The Core Image/Metal renderer is implemented. It uploads one bounded 16-bit
  preview proxy per selection and applies orientation, RawTherapee-compatible
  film negative power-law inversion, grayscale, white balance, gamma, shadows,
  highlights, HSV saturation, curves, and color wheels in one custom GPU color
  kernel.
- Render scheduling is bounded to one in-flight request and the newest pending
  parameter snapshot. Superseded snapshots are discarded without creating an
  unbounded detached-task backlog.
- The kernel is display-only. The existing 16-bit CPU correction path remains
  the authoritative reference and fallback.
- The latest 500-change 1080×720 runtime benchmark measured 2.66 ms median and
  3.37 ms p95 for the correction kernel plus `CGImage` render on the
  development machine.
- **Stage 2 GPU-vs-CPU equivalence is verified.** The model and production
  renderer are compared against `FilmProcessing.correctedPreview` across the
  current correction parameter grid. The direct Core Image renderer is
  verified across 2,655 comparisons with a maximum difference of 2/255.
- **Render instrumentation is deployed.** `AppModel.renderStats` publishes
  submitted/dropped/displayed counters plus latency metrics. `os_signpost`
  events are emitted for profiling.
- **The production-renderer Stage 3 performance gate is met.** Display-rate coalescing is implemented
  with a 17 ms inter-frame delay, capping renders at ~60 Hz. A 500-update GPU
  render burst benchmark across current-pipeline parameter combinations,
  including curves and color wheels, measured 3.37 ms p95 at 1080×720 in the
  latest local run. Scheduling contract tests verify coalescing, latest-value-wins,
  cancellation, and bounded backlog.
- A Metal-backed preview surface and the idle authoritative preview remain
  deferred (Stage 4).

## Next Step

The direct Core Image renderer is verified against the CPU path across 2,655
comparisons with zero failures and a maximum difference of 2/255. Stage 4
(Metal-backed preview surface, direct display-path instrumentation, and idle
authoritative rendering) remains deferred.

## Original Blocker

The initial still-image correction workflow loaded real RAW files and exposed
the intended controls, but did not provide useful feedback while a slider was
moving.

There are three causes:

1. The SwiftUI slider helper constructed a binding from a captured integer
   value, so its getter could remain stale during a continuous drag.
2. Every change scheduled a CPU render whose result was often discarded when
   its parameter snapshot was no longer current.
3. Cancelling the outer task did not stop detached CPU work, allowing repeated
   changes to create a render backlog.

Live bindings, a reusable GPU correction renderer, and a bounded render queue
now address those causes. The remaining work is direct Metal-backed display,
end-to-end latency measurement, and idle authoritative rendering.

## Definition Of Done

The still preview is real-time when:

- the image visibly changes throughout a continuous slider drag;
- parameter-to-display latency is below 33 ms at the 95th percentile on the
  representative RAW corpus, with 16 ms as the stretch target;
- the latest parameter value always wins and stale work does not accumulate;
- a file is decoded and uploaded to the preview renderer once, not once per
  slider event;
- the interactive preview never blocks the main actor;
- the full 16-bit CPU pipeline remains the authoritative path for idle
  verification and final export;
- preview differences from the authoritative render are measured and
  documented.

## Architecture

Use two explicitly separate render paths.

### Interactive GPU Preview

Create a `StillPreviewRenderer` backed by a Metal `CIContext` for the first
implementation, with custom Core Image or Metal kernels where built-in filters
cannot reproduce the intended controls.

On file selection:

1. Decode the RAW file once into the full-resolution `UInt16Image`.
2. Build a bounded preview proxy once.
3. Upload that proxy once as a GPU-owned image or texture.
4. Keep the source texture immutable while controls change.

For every display frame with new parameters, apply this render graph:

1. orientation and flip;
2. film-mode inversion or grayscale conversion;
3. white-balance matrix;
4. gamma, shadows, and highlights tone kernel;
5. overall and per-channel curves;
6. shadow, midtone, and highlight color wheels;
7. saturation;
8. display color conversion.

Display the renderer output through a Metal-backed preview view. Do not create
a new `NSImage` for every slider event.

### Authoritative CPU Render

Keep `FilmProcessing.correctedPreview` and the eventual full processing pipeline
as the correctness reference. Run it after interaction becomes idle, for
preview-versus-reference comparisons, and for final export.

The GPU preview is allowed to be approximate while dragging, but control
meaning and output differences must remain bounded and tested.

## Interaction And Scheduling

- Bind sliders to mutable continuous `Double` state rather than captured
  integer values.
- Publish a complete immutable parameter snapshot whenever a control changes.
- Coalesce updates to the display refresh rate. Keep only the newest pending
  snapshot; never queue one render per slider event.
- Remove the sleep-based debounce from the interactive path.
- Commit rounded `ProcessingParameters` to the selected file's durable session
  state when values change.
- After the gesture is idle, schedule one authoritative CPU render. Cancel or
  supersede earlier idle renders before they start.
- Add signposts and counters for parameter updates, submitted frames, displayed
  frames, dropped snapshots, and end-to-end latency.

## Implementation Stages

### Stage 0: Correct State Flow And Instrument It

- ~~Replace captured-value slider bindings with live bindings.~~ Done.
- Separate interactive preview requests from authoritative CPU renders.
- ~~Add bounded latest-value-wins scheduling.~~ Done.
- ~~Add scheduling tests and latency instrumentation.~~ Done (signposts,
  renderStats counters, scheduling contract tests).
- Preserve the current CPU preview as a temporary idle-render fallback.

This stage makes failures observable and prevents misleading UI behavior, but
does not by itself make the CPU renderer real-time.

### Stage 1: Core Image GPU Preview

- ~~Add `StillPreviewRenderer`.~~ Done.
- Reuse the live-camera Core Image and Metal context approach for still images.
- ~~Implement orientation, film negative inversion, grayscale, white balance,
  saturation, exposure, curves, and color wheels on the GPU.~~ Done.
- Replace per-update `NSImage` creation with a Metal-backed preview surface.

### Stage 2: Tone Kernel And Visual Equivalence

- ~~Implement gamma, shadows, and highlights in a custom `CIColorKernel`.~~
  Done for the initial renderer; migrate to a compiled Metal kernel before
  release because the source-kernel API is deprecated.
- ~~Compare a parameter grid against the CPU reference.~~ Done.
- ~~Document accepted preview tolerances and fix visibly divergent controls.~~
  Done; production-renderer maximum difference is 2/255.

### Stage 3: Performance Gate

- ~~Coalesce updates to the display refresh rate and add bounded buffering.~~ Done.
  17 ms inter-frame delay, latest-value-wins bounded to 1 in-flight + 1 pending.
- ~~Benchmark the representative RAF corpus.~~ Done. The 500-update 1080×720
  production-renderer burst benchmark, including curves and color wheels,
  measured 3.37 ms p95 in the latest local run.
- ~~Require 95th-percentile update latency below 33 ms with no render backlog
  after 500 rapid parameter changes.~~ Verified at 3.37 ms p95 in the latest
  local run.
  Scheduling contract tests confirm no unbounded backlog and latest-value-wins.

### Stage 4: Idle Authoritative Preview

- Render the full correction path after interaction stops.
- Swap to the authoritative result without changing control state or causing a
  distracting visual jump.
- Surface render failures without disrupting the interactive preview.

## Verification

- ~~Unit test that every slider setter changes the selected file's parameters.~~ Done.
- ~~Test that a burst of parameter snapshots displays the newest value and
  discards superseded snapshots without starting unbounded work.~~ Done
  (scheduling contract tests).
- ~~Test that switching files cannot display a late result from the previous
  file.~~ Done (cancellation test, generation-based guard).
- ~~Compare GPU and CPU output across representative film modes and parameter
  combinations.~~ Done (2,655 direct production-renderer comparisons,
  maximum difference 2/255).
- ~~Benchmark drag latency on representative standard images and RAF files.~~ Done.
  The latest 500-update production-renderer burst benchmark measured 3.37 ms
  p95 at 1080×720.
- Add a UI smoke test that drags each slider and confirms visible preview
  changes once reliable app automation is available.

## Risks And Decisions

- Built-in Core Image filters will not exactly match all Python correction
  stages. Custom tone kernels are required before preview behavior can be
  considered representative.
- Color management, EDR displays, and display profiles can make a fast preview
  differ from exported pixels. The display transform must stay outside the
  authoritative processing result.
- Full-resolution GPU ownership must be bounded when switching files. The first
  implementation should retain only the selected file's preview texture.
- Export is the active product priority. Stage 4 remains deferred until its
  display-path and idle-render work has higher value than the remaining
  replacement gates.
