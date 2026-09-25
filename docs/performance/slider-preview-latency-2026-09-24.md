# Slider-to-preview latency — September 24, 2026

This pass starts from `fc63454` plus the existing uncommitted code cleanup,
Film Base / LookRecipe, retained-preview, and version-4 control work. It changes
UI observation and interactive overview selection, without changing processing
math, factory recipes, saved edit schemas, export rendering, or preference
checkpoints.

## Changes

`AppModel` uses macOS Observation instead of broadcasting every property change
to the whole window and app scene. The sidebar, toolbar, inspector, preview,
and status evaluate inside separate view bodies. Preview availability has its
own observed Boolean, so replacing an image does not invalidate controls that
only need to know whether a preview exists. Inactive geometry overlays no longer
read parameters on every point edit. The existing 8ms render coalescing interval,
latest-pending queue, and stale-generation checks remain in place.

At inspection zoom, a full-RAW GPU gesture now renders its 1024px overview from
the already retained 2048px edit proxy. Previously it corrected the full source
before reducing the result, then rendered the visible detail separately. The
visible detail still uses the full source with the same settings and pixel
coordinates. CPU fallbacks keep their existing route. Releasing the gesture
still queues an exact complete raster; temporary overviews never enter the
corrected-raster cache. No additional persistent image or renderer is retained.

## Measurement protocol

The existing native-window runner uses production ContentView/AppModel,
NSScrollView, and the full 7752×5184 Fuji 400 DSCF2833 RAW with C-41 / Clean Invert
(version 2). It replays 120 programmatic Exposure or Contrast changes at nominal
120Hz, at Fit and 100%. The native window is observed through ScreenCaptureKit
using a revision marker in the same hosted content as the image. It retains
numeric timing and marker observations, not captured screen images or audio.

This measures setter-to-capture delivery, not physical screen scan-out or native
mouse-event latency. Worker compute and time waiting to resume on the main actor
are recorded separately. Input lateness and actual gesture duration are retained;
a nominal 0.992-second input sequence can take much longer when the main thread
is busy. Reported rates count distinct composited revisions during that actual
gesture. These are sequential same-machine runs, not interleaved binary A/B
trials or population tail estimates. Capture and instrumentation add overhead.

The fresh baseline has three counterbalanced repetitions. An intermediate UI-only
run has one repetition and establishes that observation changes help independently
of the overview optimization. Source, input, and binary hashes are retained by
the runner. The baseline's timing varies substantially across repetitions, so
comparisons must show its range rather than only its slowest case.

The final run repeats the baseline's three-repetition cohort on an Apple M4 Pro
(Mac16,7), macOS 15.7.9, Swift 6.1.2, LibRaw 0.22.2, 48 GiB RAM, and a 120Hz
display. All runs have the same 658×821-point preview viewport and 2× backing
scale. The table's latency values are medians of the six per-case medians for
each view; rates show the full six-case range.

| View | Setter → capture callback, baseline → final | Distinct composited revisions/s, baseline → final | Actual gesture duration, baseline → final |
|---|---|---|---|
| Fit | 94.00 → 52.94 ms | 17.17–30.03 → 44.72–48.32 | 3.86–6.76 → 2.32–2.48 s |
| 100% | 126.12 → 55.87 ms | 15.15–19.67 → 42.57–44.49 | 5.79–7.52 → 2.56–2.61 s |

Per-case median callback latency ranges are 80.30–129.79 → 50.96–54.36 ms at
Fit and 109.61–141.62 → 54.75–57.48 ms at 100%. Thus the final cases exceed the
40-revision/s diagnostic target, but do not reach 120Hz input cadence.

The UI-only run reaches 45.41–46.13 revisions/s at Fit, while 100% still reaches
18.07–19.33. With the proxy overview, 100% median worker compute falls from
39.84 ms in the baseline and 38.44 ms in the UI-only run to 14.27 ms. Fit's
median worker time remains about 6 ms; its median wait to resume on the main
actor drops from 31.89 to 13.89 ms. UI work is still material.

Final release-to-capture refinement takes 218.63–233.74 ms across both views,
versus 238.40–468.70 ms in the baseline. This wait remains after the responsive
gesture preview. These values include capture delivery, not just processing.

The final run decodes 1,796 complete marker frames and excludes nine transitional
frames without a valid marker; the baseline decodes 3,066 and excludes nine.
Every case has compositor evidence, current-parameter/full-raster refinement,
no trace/capture overflow, and successful model release. Process peak footprint
falls from 1,575.82 to 1,180.13 MiB, and post-model-release footprint from 778.63
to 382.08 MiB. These are process-wide samples, not retained-cache byte counts or
a guarantee that frameworks return all memory immediately.

Local evidence roots:

- `dist/preview-latency-baseline-2026-09-24/`
- `dist/preview-latency-observation-2026-09-24/`
- `dist/preview-latency-optimized-2026-09-24/`
- `dist/preview-latency-validation-2026-09-24/`

## Verification

The focused release run passes **15 tests, one opt-in skip, zero issues**,
9.455 seconds. It includes property-observation isolation, atomic wheel edits,
undo/persistence, stale-frame rejection, native viewport remapping, bounded
overview selection, and real-RAW detail/full-raster agreement within 1/255.
The independent real-RAW draft/inspect/full preview-scale probe also passes
(one test, 6.031 seconds). Both use the final source and binaries; their timing
values are not compared with unmatched historical workloads.

The first focused run passed the existing editing,
publication, and viewport tests, but the new observation test waited for a
statistics update while the gesture's existing 100ms throttle intentionally
withheld it. The test now waits for release to flush statistics. The failing log
is retained; no scheduling change was made to accommodate the test.

The complete release regression passes **728 tests, 16 explicit opt-in skips,
zero issues**, 392.732 seconds. The native-window replay and preview-scale probe
are among those skips and were run separately above. Strict formatting passes
for all nine changed/added Swift files, and whitespace checks pass. Source and
app/test binary hashes match the final measured run after regression. The
validation manifest lists the exact skipped tests and changed source files;
all other native/runner source hashes match the baseline.

No standalone comparator, photographic preference gallery, representative-roll
export, energy study, packaged release, or native pointer replay has been rerun
for this pass. Default synthetic GPU/CPU and RAW reference-pixel tests are covered
by the complete suite; they are not a new photographic or export study.

## Reproduction

Use normal macOS graphics access and existing Screen Recording permission. The
runner captures only its diagnostic window, does not prompt for permission, and
uses temporary preferences/settings. Choose a fresh ignored output directory.

```sh
.venv/bin/python native/diagnostics/run-preview-interaction-study.py \
  --output dist/preview-latency-next --repetitions 3 --events 120
swift test --disable-sandbox -c release --package-path native/FilmScanEngine --no-parallel \
  --filter 'AppModelObservationTests|WheelEditingPerformanceTests|PreviewPublicationTests|ViewportRenderingTests|PreviewScrollViewTests|rawPreviewUpgradesAutomaticallyToFullResolution'
```

Run timing workloads sequentially and do not change native sources or rebuild
another product during a recorded replay. The [test guide](../../tests/README.md)
and [native contracts](../../native/README.md) include the independent real-RAW
preview-scale probe and the complete regression command.
