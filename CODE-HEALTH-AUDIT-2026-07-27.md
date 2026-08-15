# Film Scan Converter — Validated Native Code-Health Audit

**Date:** 2026-07-27  
**Scope:** Swift engine, macOS SwiftUI app, native tests, and native CI  
**Excluded by request:** the legacy Python implementation  
**Status:** source-verified and updated after corrective changes

## Executive summary

The original audit substantially overstated severity. It did identify several real
problems, but none of the reviewed Swift findings was a critical defect. Large
files and small helper duplication are maintenance costs, not release-blocking
failures. Several crash and correctness claims were based on invariants that the
code already enforces.

The highest-confidence native issues have now been corrected:

- edit overlays are mutually exclusive through one typed state;
- footer status severity is typed and follows the status actually displayed;
- failed preview/profile loads retain useful diagnostics;
- all image export formats stage and commit atomically;
- a failed export cannot delete a pre-existing destination;
- the two remaining large correction/warp loops use disjoint parallel ranges;
- full-frame channel medians use a fixed-size histogram instead of sorting every
  source value;
- duplicated unsafe-buffer wrappers and overlay geometry helpers are shared;
- overlay controls have VoiceOver labels, hints, and keyboard-accessible actions;
- malformed standard-image and RAW inputs have regression coverage;
- native CI now tests macOS 14 and 15 and emits code-coverage reports/artifacts.

The remaining findings are mostly bounded refactors, missing failure-injection
seams, corpus/benchmark CI work, and a formatting baseline.

## Disposition of the original findings

Original numbers are retained so review comments can be traced back to the first
version of this document.

| Disposition | Original finding IDs |
|---|---|
| Implemented | 2, 8, 9, 16–18, 24–25, 35–36, 38–40, 53, 66–68 |
| Partially implemented | 61 |
| Confirmed, still open | 1, 5–7, 10–15, 27–28, 30, 33, 47, 49–52, 59, 62–65 |
| Rejected or materially reframed | 22, 23, 26, 29, 31, 32, 34, 37, 48, 60 |
| Python; intentionally not assessed | 3, 4, 19–21, 41–46, 54–58, 69 |

## Implemented findings

### 2 — Shared mutable-buffer wrapper

**Validated severity:** low maintenance issue, not critical.

The repeated `@unchecked Sendable` pointer boxes are now one internal
`SendableMutableBuffer` used by image packing, DNG packing, negative processing,
correction processing, and perspective warping. The unsafe contract remains
small and reviewable in one file.

### 8 and 9 — Duplicate overlay geometry helpers

**Validated severity:** low.

The four copies of aspect-fit and point-clamping logic now live in the tested
`PreviewOverlayGeometry` utility beside the extracted overlay views.

### 16 and 18 — Serial correction and perspective loops

**Validated severity:** real performance opportunity.

`correctedPreviewPowerLaw`, `correctedPreviewDensity`, and `warpPerspective`
now switch to bounded `DispatchQueue.concurrentPerform` work above one million
pixels. Workers receive non-overlapping output ranges. Small images retain the
serial path to avoid dispatch overhead.

Million-pixel identity/parity tests exercise both parallel paths and compare the
entire output.

### 17 — Full-source median sorting

**Validated severity:** real memory and CPU issue for large scans.

`channelMedian` no longer allocates and sorts one `UInt16` per sampled pixel.
It accumulates a 65,536-bin histogram and selects the middle rank in linear time
with fixed auxiliary memory.

### 24 and 25 — Named color math and shared conversions

**Validated severity:** readability and maintenance issue.

Rec.2020, Rec.709, and BT.601 luminance weights are now named so similar-looking
formulas cannot be mistaken for interchangeable standards. Identical percentile,
smoothstep, finite-value, and Float/Double HSV conversion helpers now have one
implementation with focused regression coverage.

### 35 — String-based status classification

**Validated severity:** real UI correctness issue.

The old footer could display `camera.status` while coloring it using
`model.status`, and its case-sensitive substring checks missed other error
phrasing. `AppModel` and `CameraController` now publish a `StatusKind` beside
their message, and the footer reads both fields from the same active source.

### 36 — `AnyView` in curve point details

**Validated severity:** small SwiftUI cleanup; the original performance impact
was overstated.

The curve point row now uses `@ViewBuilder` and retains normal structural
identity.

### 38 — Independently toggled preview overlays

**Validated severity:** real interaction-state defect.

Rebate selection did not close perspective, straighten, or crop editing, so
multiple hit-testing overlays could be active. A single `PreviewOverlay?` state
now owns rebate, perspective, straighten, and crop modes. Transitions run the
correct cleanup and preserve/restore `showOriginal` where required.

### 39 — Silent preview and profile failures

**Validated severity:** real diagnostics gap in the cited user-facing paths.

Fast preview extraction now logs the underlying decoder error and renderer
creation failure. Capture and film-stock profile loading no longer uses
`compactMap { try? ... }`; corrupt profile IDs and errors are logged and the app
shows a count of profiles it could not load. Best-effort metadata probes that
legitimately return an optional dimension remain optional.

### 40 — Overlay accessibility

**Validated severity:** real accessibility gap.

Straighten, manual crop, perspective corners, and film-base selection now expose
labels and hints. Perspective corners have named one-percent nudge actions;
straighten, crop, and film-base modes have useful named actions. The visual-only
corner loupe is hidden from the accessibility tree.

### 53 — Export cleanup

**Validated finding, corrected diagnosis:** the risk was not merely an orphaned
partial file. `ExportManager` unconditionally removed the requested destination
after any writer error, which could erase a file that existed before the export.

JPEG and TIFF now join PNG and DNG in writing to a unique sibling staging file
and atomically replacing/moving only after successful finalization. The manager
does not delete the final destination on failure. A regression test begins with
an existing destination, forces an unsupported PNG export, and verifies the
original bytes remain unchanged.

### 61 — Malformed media tests

**Status:** partially implemented.

New tests cover truncated PNG data in both the full and preview standard-image
decoders, plus truncated RAF data in full decode and thumbnail extraction.
Zero-byte variants would be redundant with these decoder entry paths. Filesystem
full/permission and interrupted-commit tests still require a filesystem
injection seam.

### 66 — Formatting baseline and CI gate

The native package source and tests now conform to `swift format`, and the
macOS 15 CI lane runs strict recursive linting. The prior formatting baseline is
therefore fixed rather than hidden behind disabled rules.

### 67 and 68 — Coverage and supported-macOS CI

**Validated severity:** real CI coverage gaps.

The native workflow now runs on both `macos-14` (the deployment target) and
`macos-15`, enables Swift coverage, prints an `llvm-cov` report, and uploads the
instrumentation profile for each runner. Release packaging remains on macOS 15
only to avoid duplicating artifact work.

## Confirmed findings still open

### Maintenance boundaries

- **1:** `AppModel.swift`, `ContentView.swift`, and
  `FilmNegativeProcessing.swift` remain large and multi-purpose. This is a
  merge-conflict and reviewability cost, not a critical runtime issue. Preview
  overlays and their testable geometry have been extracted from `ContentView`;
  further splits should remain feature-oriented.
- **5–7, 10–15:** several pure helper and processing blocks remain duplicated.
  They should be consolidated opportunistically when those areas next change;
  a broad mechanical refactor has less value than the original audit claimed.
- **30:** the already-documented Python-compatible coordinate truncation could
  be made clearer. Current behavior is intentional.
- **27–28:** the morphology integral buffer and contour root pass have plausible
  memory/work reductions. Any narrower integer type must prove overflow bounds
  against maximum supported image dimensions before adoption.

### App and API cleanup

- **33:** reusable component previews would improve SwiftUI iteration, although
  views tied to live app state need fixtures or injected models first.
- **47, 49–52:** access-level consistency, fixed layout constants, and failure
  reporting around profile-directory/log-file setup remain low-priority cleanup.

### Testability and CI

- **59:** there is no explicit stress test combining import, editing, cache
  invalidation, and export. Main app state is `@MainActor`, but task cancellation
  and stale-result rejection would still benefit from a deterministic stress
  test.
- **62:** `StillPreviewRenderer` has no injected pipeline/compiler failure seam,
  so Metal compilation and allocation failures are not directly testable.
- **63:** `CameraController` directly owns AVFoundation discovery/session setup;
  permission denial, disconnection, and add-input/output failures need protocol
  seams before unit tests can drive them.
- **64:** the optional local RAW corpus is not present in CI, so corpus-dependent
  decode and calibration tests are skipped. A redistributable, licensed fixture
  subset or secured CI artifact is required.
- **65:** benchmark executables exist but do not run on a scheduled, hardware-
  controlled regression lane.
## Rejected or reframed findings

- **22:** force-unwrapping the platform sRGB color space is an invariant over a
  macOS framework constant, not a recoverable user-input crash path.
- **23:** the private coordinate-ordering helper is reached only after its
  public entry point establishes the required four-point invariant.
- **26:** file-private conversion helpers do not pollute the public module API;
  namespacing them is stylistic.
- **29:** intermediate clamps separate processing-stage domains and cannot be
  removed as a blanket optimization without numerical parity evidence.
- **31:** automatic rebate candidate search intentionally discards regions that
  cannot be measured; expected candidate rejection is not an actionable app
  error.
- **32:** perspective corner indices come from a fixed four-element collection.
  The precondition protects a programmer invariant, not untrusted user input.
- **34:** the cited `ContentView` helpers map values to labels, menu choices, and
  bindings. They are presentation logic rather than business rules.
- **37:** the claimed stale `showOriginal` state was not reproducible because
  selection changes ended the active modes before loading. The overlay state was
  nevertheless simplified as part of finding 38.
- **48:** mapping the closed range directly creates the requested LUT; it does
  not first allocate the claimed discarded `[Int]` array.
- **60:** `didReceiveMemoryWarning` is an iOS/UIKit concept and is not an
  applicable macOS test requirement. Cache eviction already has direct tests;
  allocation-failure behavior belongs under injected failure testing.

## Verification performed

- Strict recursive `swift format lint` completed with zero diagnostics across
  the package manifest, production sources, and tests.
- The shared color-math, overlay-geometry, processing, render-ready image, and
  protected-color focus run completed with **167 tests passed**; the focused
  profile-store run completed with **31 tests passed**.
- `swift build --package-path native/FilmScanEngine --product FilmScanConverterMac`
  completed successfully.
- A focused native run covering exports, processing, negative processing,
  perspective warp, app-model integration, standard decoding, and the new
  truncated RAW case completed with **268 tests passed**.
- A coverage-enabled export run completed with **27 tests passed**.
- The exact CI `llvm-cov report` command was executed successfully against the
  instrumented debug test bundle and generated a source coverage table.
- The complete native suite was discovered successfully with **422 tests**. A
  prior full local run
  was stopped during the unusually large optional local RAW corpus, after the
  ordinary integration and processing suites had passed; this document does not
  claim that corpus-heavy full run completed.

## Recommended next work

1. Add injectable renderer and AVFoundation seams, then cover findings 62–63.
2. Establish a redistributable RAW mini-corpus for CI (64).
3. Add a scheduled benchmark lane with stable hardware and stored thresholds
   (65).
4. Split `AppModel` and `ContentView` by feature only as those areas are changed,
   keeping each extraction behavior-preserving and independently tested (1).
