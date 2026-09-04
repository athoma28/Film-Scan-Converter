# Native code and bug audit — 2026-09-02

## Scope and result

Reviewed the native Swift/macOS app, processing engine, RAW bridge changes,
and tests at commit `2732581`, including the nine existing modified source
files. Used the earlier native audit and the changes since `ba06110` to guide
the review. The legacy Python app was not reassessed.

Found two high-priority image-correctness defects, three additional workflow
bugs, and several bounded cleanup items. All findings were subsequently fixed
at the user's request, preserving the existing inspector and performance
changes. The findings below record the original defects and reproductions.

## Implemented resolutions

1. **B&W curves:** overall tone curves now affect Natural, Classic, GP3, and
   basic-inversion B&W on both CPU and GPU. Color-channel curves are gated to
   color film types, including cached LUTs when switching film types. Saved
   color adjustments cannot tint monochrome output. The standalone
   `applyCurves` utility retains its existing channel-processing behavior.
2. **Stack correctness:** preview and export share one full-resolution path
   that registers each original capture against the original reference.
   Original samples are stored temporarily and merged in bounded row bands,
   retaining robust outlier statistics and original HDR exposure weights.
   Automatic mode considers the exposure spread of the complete stack.
3. **Independent manual crop:** manual-crop status and Clear remain visible
   alongside automatic or perspective cropping. Clearing the manual crop
   retains the preceding geometry.
4. **Visible diagnostics:** crop and film-base status messages are restored
   below their controls, including failures without an existing result.
5. **Stack upgrade errors:** intermediate tiers can be skipped, while a failed
   final tier reports the failure and retains the bounded preview. The stack
   card shows that status after loading ends. Background redraws preserve
   errors; retrying clears the prior error and can complete successfully.
6. **Remaining cleanup:** crop dimension labels count each stage once;
   Advanced Color Science is disabled outside color negatives; the stack
   toggle retains its accessibility label; obsolete inspector and wheel
   helpers were removed; histogram median rank selection is shared; strict
   Swift formatting is clean.

Regression coverage includes a four-capture export with contamination in the
second capture, exact full-resolution preview pixels, translated HDR row
bands and clipped edges, monochrome stacks, temporary-file cleanup on success,
failure, and cancellation, failed upgrade/retry, geometry dimensions and
independent reset, sorted-sample histogram medians, and B&W GPU/CPU curves.

Full-resolution stacking trades temporary disk space for bounded resident
image storage: approximately two bytes per channel per pixel per capture,
removed after the operation. Release packaging, the full local RAW corpus,
opt-in performance benchmarks, and hands-on camera/roll checks remain outside
this fix pass.

## Final verification after fixes

- Release build succeeded with no compiler warnings, including the native
  app, engine, preview renderer, and test runner.
- The normal-graphics release regression run passed: Swift Testing reported
  **513 tests**, comprising **505 passing test records and 8 explicit skips**.
  The command used `--no-parallel --skip
  'RawImageDecoderTests|CameraScanByteIdentityTests'`; the two extensive local
  RAW-corpus suites were excluded. The eight skips are opt-in performance
  and representative-roll checks.
- `FilmScanPreviewComparator` completed **2,725 comparisons**, with Metal
  available, **zero render failures**, and maximum difference **2/255**.
  Its B&W grid had a maximum difference of **1/255**. The additional Natural,
  Classic, GP3, and basic-inversion curve regression passed within **2/255**.
- Strict recursive `swift format lint` over the manifest, Sources, and Tests
  returned **zero diagnostics**. `git diff --check` passed.
- Focused tests initially exposed a nested test macro compile issue, a
  background-render status race, and a standalone curve-helper compatibility
  regression. All were corrected before the successful final run.

Final logs: `/tmp/film-scan-fixes-tests.log`,
`/tmp/film-scan-fixes-comparator.log`, and `/tmp/film-scan-fixes-lint.log`.

## Confirmed bugs in the reviewed version

### 1. [P1] Newly enabled B&W curves can make export disagree with preview

**Location:** `ContentView.swift:992–1031`; related processing in
`Processing.swift:181–184` and `StillPreviewRenderer.swift:1231`.

The inspector now places the curve editor under `supportsToneCorrections`,
which enables it for B&W. Previously it was gated by `supportsColorCorrections`.
The rendering paths do not support that change consistently:

- Natural B&W retains three channels, so CPU processing applies the curve.
  The GPU kernel skips the curve LUT whenever `isBW` is true.
- Classic B&W becomes one channel, so CPU processing also skips curves.
  The enabled control has no effect in that mode.

A synthetic Natural B&W test with a curve through `(0,0)`, `(0.5,0.1)`, and
`(1,1)` changed CPU output while leaving GPU output unchanged. The maximum
preview/export difference was **109/255**, against the normal 2/255 tolerance.
A separate Classic B&W check confirmed unchanged pixels.

**Fix:** Restore the curve-specific capability gate, or implement consistent
monochrome curve behavior across the CPU and GPU. Keep per-channel controls
separately gated if only a luminance curve is supported. Add both Natural and
Classic B&W curve cases to parity coverage.

### 2. [P1] Incremental stacking defeats robust outlier rejection

**Locations:** `AppModel.swift:2624–2629` and `3643–3648`.

Full-resolution preview and export duplicate the accumulated composite
`index` times before passing it, plus the next capture, to `MultiScanStacker`.
Those copies are treated as independent observations by the robust merge.
Starting with the third capture, the identical copies have zero residual
variance; a valid new capture can therefore be rejected as the sole outlier.
Contamination already averaged into the first pair becomes entrenched.
Original HDR confidence weights are also lost when captures are collapsed
into an encoded composite.

The reproducer used four 96×72 RGB captures, with an 8×8 contaminated patch in
the second capture. The existing all-captures merge recovered the clean image
with linear MSE **3.92e-12**. The app's incremental algorithm retained the
patch with MSE **6.20e-4**. Both app paths contain the same algorithm; bounded
previews use the all-captures merge, so quality can change during upgrade.

**Fix:** Preserve independent-sample statistics and HDR weights through a
streaming merge, or merge original samples in bounded image tiles. Do not
represent accumulated statistical weight by duplicating an averaged image.
Add an app-path regression with at least three captures; current app workflow
tests exercise two-capture stacks.

### 3. [P2] A manual crop cannot be cleared independently when another crop exists

**Location:** `ContentView.swift:1257–1270`.

The manual-crop controls are now an `else if` after perspective and automatic
crop controls. Manual cropping is a separate, subsequent geometry stage and
can coexist with either. After applying perspective or Auto Frame and then
Manual Crop, the manual crop's status and Clear button disappear. The
remaining Clear button removes the earlier geometry; Auto Frame's Clear
also removes the manual crop.

**Fix:** Display the manual-crop block with an independent `if`, as before.
Verify that clearing it retains the perspective or detected frame.

### 4. [P2] Frame and film-base failures have lost their visible diagnostics

**Locations:** `ContentView.swift:1273–1309` and `1432–1464`.

The rewritten sections no longer read `model.cropStatus` or
`model.rebateStatus`. Those fields are the only destinations for messages
such as “No crop frame detected,” “No clear unexposed film edge detected,”
and film-base measurement failures. The footer reads the separate
`model.status`. Failed operations therefore finish without explaining the
outcome to the user.

**Fix:** Restore the relevant status text below the detection and sampling
controls, including unsuccessful operations with no existing measurement.

### 5. [P2] Stack upgrade failures are swallowed after the first successful tier

**Location:** `AppModel.swift:3552–3558`.

Once a bounded stack exists, the inner catch continues after every later
decode/alignment error, including the final full-resolution tier. The loop
then clears the busy flags as if it completed. The outer catch's intended
“Showing the bounded stack; full-resolution upgrade failed” message is never
reached for these errors, and the status can remain “Loading full-resolution
stack.” The current sidebar also hides stack status when neither busy flag
is set.

**Fix:** Continue past an intermediate failed tier if useful, but report the
final tier's failure and visibly identify the retained bounded preview.
Preserve cancellation handling separately. This finding is verified by
control-flow inspection; deterministic tier-failure injection is absent.

## Smaller findings in the reviewed version

- **Crop dimensions are scaled twice.** At `ContentView.swift:1248` and
  `1264`, a crop fraction is multiplied by `selectedCanvasDimensions`, which
  already includes that crop. A 50% crop of a 1000 px canvas is reported as
  250 px instead of 500 px. Use the resulting dimensions directly, or the
  dimensions immediately before the relevant crop stage.
- **Capability gating was also removed from Advanced Color Science.** The
  controls at `ContentView.swift:1562` are offered for slide, B&W, and Crop Only
  even though those processing paths do not apply dye mixing. Restore a
  capability gate around the section.
- **The stack toggle has an empty accessibility label.** At
  `ContentView.swift:232`, `Toggle("")` replaced “Use aligned stack.” Retain a
  meaningful label while hiding it visually.
- **Formatting fails the required CI gate.** Strict `swift format lint`
  returned 14 diagnostics, all in `ContentView.swift`. Fix these before
  committing; the macOS 15 CI lane treats them as failures.
- **Remove obsolete helpers.** `InspectorChoiceCard`, `InspectorChoiceRow`,
  `InspectorChoiceChip`, `densityRow`, and `pointText` have no callers after
  the inspector rewrite. `Processing.applySingleWheel` is also unused after
  the wheel optimization.
- **Consolidate shared logic when fixing these areas.** Full-resolution stack
  preview/export duplicate the faulty accumulation loop. Histogram median
  rank selection is duplicated between `computeMedians` and `channelMedian`.
  Share those small units; broad file splitting is a lower priority than the
  correctness defects above.

## Original audit verification

- Release build and test discovery succeeded, including the macOS app.
- The existing regression run with normal macOS graphics access succeeded:
  Swift Testing reported **505 tests**, with **497 passing test records and
  8 explicit skips**. The run excluded `RawImageDecoderTests` and
  `CameraScanByteIdentityTests`, which contain extensive local-corpus checks.
  Other enabled RAW/app integration checks in the selected suites ran.
- Three focused reproducers confirmed the stack defect, Natural B&W GPU/CPU
  mismatch, and ineffective Classic B&W curve. Their expected-behavior
  assertions fail on the reviewed code. The temporary test source was removed
  from the package after verification.
- The initial sandboxed run had graphics failures and terminated during a
  SwiftUI layout test. The three thumbnail checks passed immediately with
  normal graphics access, and the subsequent broad graphics-enabled run
  passed. Those sandbox failures are not counted as application bugs.
- This audit did not run the entire RAW corpus, opt-in performance/roll
  benchmarks, release packaging, or a hands-on camera session. It does not
  establish performance gains from lowering parallel-work thresholds.

Temporary evidence from this session is available in
`/tmp/film-scan-audit-tests-graphics.log`,
`/tmp/film-scan-audit-regressions-graphics.log`,
`/tmp/film-scan-audit-regression.swift`, and
`/tmp/film-scan-audit-lint.log`.
