# Ordinary slider response and native interaction — September 24, 2026

This study follows the photographic tone v2 implementation with ordinary edits,
combinations, and a real native preview window. It measures two separate gaps:
what an adjustment does to a photograph, and how quickly the composited preview
follows it. It does not establish Camera Raw equivalence.

**Historical v2/v3 study.** Its version-3 response was an explicit trial. The
current source defaults new neutral edits to version 4 and keeps factory looks
at version 2; see the [later tone-range study](tone-range-separation-2026-09-24.md).
The timing and photographic findings below apply to the recorded source and
cohort.

## Baseline photographic evidence

`dist/tone-response-study-2026-09-24/` contains a completed, source/input-hashed
production run: six archived 900px photographs, 27 Clean Invert variations and
six variations with modest warmth/tint/saturation/vibrance, totaling 198 renders.
All 198 CPU/Metal comparisons pass; maximum channel difference is 1/255.
The gallery, exact processing parameters, fixed region overlays, CSV/JSON
measurements, linear-signal probes, logs and executable are retained together.

The frames are Fuji 400 DSCF2833/DSCF2892, Pro Image DSCF5800/DSCF5809 and
Phoenix II DSCF3079/DSCF3091. They include skin, foliage, deep backgrounds,
bright windows, pale surfaces, and saturated non-skin colors. This is a bounded
diagnostic cohort, not unseen-profile validation or a fit to Camera Raw.

The ordinary-edit sweep uses exposure ±0.25/0.5 EV and brightness, contrast,
highlights and shadows ±0.1/0.25, plus six combinations. These are increments
from the exact saved baseline, including Clean Invert's nonzero Highlights and
Shadows. The additional color context uses temperature +15 mired, tint +0.08,
saturation +0.2 and vibrance +0.15. It is an interaction probe, not a proposed look.

Findings motivating a focused Highlights/Shadows trial:

- Shadows +0.25 lifts the middle luminance fifth more than the darkest fifth in
  five of six frames. Adding Contrast +0.1 then makes the darkest fifth darker
  than baseline in four frames, while still lifting the middle. For Pro Image
  DSCF5809's sampled dark background, Shadows alone adds 1.21 display codes,
  Contrast alone subtracts 1.54, and the combination subtracts 0.52.
- Highlights −0.25 moves Phoenix DSCF3091's leg sample by −7.52 display codes
  but its pale path by only −1.41. In Pro Image DSCF5800 the middle fifth moves
  −6.52 versus −3.12 in the brightest fifth. These are responses of sampled
  output regions, not measurements of latent RAW highlight recovery.
- Most Clean Invert color changes are small: Exposure +0.5 EV has content hue
  p95 at most 0.235°. The largest relative-chroma changes with added color
  mostly coincide with an out-of-gamut matched-luminance reference. For example,
  the warm/saturated Phoenix path loses about 25.45% relative chroma, but 98.1%
  of its reliable samples have an out-of-gamut proportional-color reference.
  This does not justify reordering the entire color pipeline.
- None of the 1,980 region rows has black/near-white channel occupancy under the
  recorded thresholds. This does not prove absence of all tonal compression.
  A separate synthetic signal probe finds a small positive-exposure reversal
  above unit input (maximum display step 0.376/255); these photographs do not
  establish that they exercise it.

Regions and quintiles are fixed from the first baseline. Hue excludes unreliable
low-chroma pixels and reports exclusions. Relative chroma is C/L in OKLab;
matched-Y color-ray residual separates changed lightness from proportional-color
departure, with outside-gamut counts alongside it. Bandpass RMS includes edges
and grain and is only a texture/contrast proxy. Kernels are contained inside
each named rectangle; 66 fine-scale and 627 coarse-scale rows are unavailable
because the region is too small. Tiny cheek/face regions cannot support a
texture-retention claim. No single metric is an aesthetic quality score.

## Baseline native interaction evidence

`dist/preview-interaction-baseline-2026-09-24/` contains three counterbalanced
repetitions of Exposure and Contrast at Fit and 100%, 120 programmatic inputs
per gesture, on the full 7752×5184 Fuji DSCF2833 RAW. The environment is an
M4 Pro, macOS 15.7.9, Swift 6.1.2, LibRaw 0.22.2 and a 120Hz display.

| View | Distinct composited revisions/second | Actual duration of nominal 0.992s gesture |
|---|---:|---:|
| Fit | 28.19–29.54 | 3.93–4.12s |
| 100% | 20.22–24.65 | 4.62–5.59s |

The diagnostic uses production ContentView/AppModel/NSScrollView in a native
window. Only that window is captured through ScreenCaptureKit. A checksum-marked
revision indicator shares the preview's hosted content. The saved evidence is
numeric timing/marker data; no captured screen images or audio are retained.
Screen Recording access must already be granted; the test does not prompt.

Counts include only distinct published revisions first observed during the
measured gesture, divided by actual gesture duration. Sample PTS differences
measure inter-revision gaps. Setter-to-callback intervals use a shared
ContinuousClock origin and include ScreenCaptureKit delivery; the two clocks
are never mixed. The marker is not a checksum of preview pixels. This is neither
physical screen scan-out nor native mouse-event latency. Instrumentation and
capture impose overhead, so compare matched runs and retain the raw observations.
The 40/s target is reported honestly, not used as a flaky pass/fail assertion.

The first smoke run completed gestures but failed the model-release gate. Its
failed artifact remains in `dist/preview-interaction-smoke-2026-09-24/`. Scoping
replay locals separately and retiring the hosted graph before window teardown
fixed the diagnostic lifecycle. The second smoke run and full baseline pass
model release, final current-parameter/full-raster refinement and evidence gates.

A separate, two-second stack sample of the frozen baseline test binary found
673/1,137 main-thread samples in SwiftUI graph reconciliation, and 441/1,137 in
AppKit display/Core Animation work. Image preparation/color conversion accounts
for 138/1,137 samples within the latter. Sampling overlaps the Fit Contrast
gesture. These are stack sample proportions, not additive stage timings or
population estimates. Both app and test executable hashes matched the baseline
before and after. The sampled replay is excluded from timing comparisons;
artifacts are in `dist/preview-interaction-profile-2026-09-24/`.

The bounded UI candidate changes the Develop inspector's eager vertical stack
to a lazy stack, retaining its contents and spacing. Offscreen control sections
then need less construction/layout work on every model publication. Additional
opt-in trace events separate detached-worker compute from delay resuming on the
main actor; native viewport entry/exit is timed independently. Missing worker
events in older artifacts mean unavailable evidence, not zero milliseconds.

`dist/preview-interaction-lazy-inspector2-2026-09-24/` completes the same
three-repetition, 120-input cohort after that change:

| View | Distinct composited revisions/second | Actual gesture duration | Release to final capture callback |
|---|---:|---:|---:|
| Fit | 37.76–39.35 | 2.95–2.98s | 171.63–203.56ms |
| 100% | 23.24–26.37 | 3.05–3.19s | 172.03–183.79ms |

Fit's per-case median worker compute is 5.11–5.26ms, followed by 19.33–19.67ms
waiting to resume on the main actor. At 100%, median worker compute is
27.87–28.59ms, with variable 2.94–19.61ms main-actor resumption. The native
viewport setter itself is about 0.01ms; that excludes deferred layout/display.
Fit thus still has substantial UI overhead, whereas zoomed rendering itself
also exceeds a 25ms frame budget. The desired 40/s target is not met.

The run decodes 2,275/2,281 complete capture frames; six transitional frames have
no valid marker and are excluded rather than guessed. All cases have compositor
evidence, no trace/capture capacity overflow, and successful model release.
Physical footprint before/after release is 103.44/779.42MiB, peak 1,577.24MiB,
versus baseline 102.69/778.30MiB and peak 1,576.28MiB. Model release is not a claim
that framework/allocator footprint returns immediately to launch levels.

These are sequential same-machine processes with counterbalanced cases within
each process, not an interleaved binary A/B experiment. The later build also adds
worker/viewport timestamps and the opt-in v3 branch; replay settings remain v2.
Report the observed improvement with those limits, not as an app-wide guarantee.
The earlier `lazy-inspector` attempt failed to compile a new test's integer-map
expression; explicit intermediate types fixed that diagnostic test. Its failed
manifest/build log is retained, and no measurements from it are used.

## Explicit Highlights/Shadows trial

Nested photo-adjustment schema 3 changes only the two range curves. For a
normalized range position `t`, the mapping is `t*g / (1-t+t*g)`, with shadow gain
`g = 2^(2*s*(1-t))` and highlight gain `g = 2^(2*h*t)`. Shadows retain the encoded
0–0.65 range, Highlights 0.4–1. The shared join keeps unit slope. The derivative
in logit coordinates is bounded below by `4 - 2*ln(2) > 0` at the public limits,
so each bend is strictly monotone. Black/white endpoints remain fixed. Exposure,
brightness, contrast, curve order, protected color and final gamut handling are
unchanged; zero Highlights/Shadows uses the exact v2 arithmetic.

For this trial, the public default schema stayed at 2; a separate
maximum-supported version accepted explicit v3 trial recipes. Factory looks and
the existing legacy upgrade remained v2. Older builds rejected v3 saved edits.
More response in deep shadows can also make grain and casts more visible, so
monotonicity is not sufficient grounds to promote this curve as a default.
Active-v3 full-resolution cost and export
agreement are separate from the v2 native interaction benchmark.

`dist/tone-response-focused-2026-09-24/` completes 240 paired photographic
renders, 2,400 own-baseline region rows and 1,200 same-edit rows. Every photographic
CPU/Metal comparison passes with maximum channel error 1/255. All five freshly
rendered preferred-look PNGs match their original hashes, and every candidate
has a schema-2 correction document captured through the production LookRecipe
API. The documents carry nested tone version 3; they preserve the destination's
film base, dye settings and framing, so reproducing these images requires the
same base/input. Nothing is installed in the user's preset library.

Shadows +0.25 / Contrast +0.1 now brightens the darkest fifth in all six frames.
The table is change from **each version's own baseline**, using identical fixed
pixel memberships. It therefore excludes the nonzero-preset baseline offset.

| Frame | v2 darkest-fifth change /255 | v3 darkest-fifth change /255 |
|---|---:|---:|
| Fuji DSCF2833 | −0.75 | +2.97 |
| Fuji DSCF2892 | −0.64 | +3.13 |
| Pro Image DSCF5800 | +5.69 | +6.05 |
| Pro Image DSCF5809 | −0.51 | +3.36 |
| Phoenix DSCF3079 | +0.27 | +4.07 |
| Phoenix DSCF3091 | −0.34 | +3.78 |

The sampled Pro Image DSCF5809 dark background changes from −0.52 to +2.62
display codes, while its face response stays close (+6.16 to +6.48). For
Highlights −0.25, Pro Image DSCF5800's middle-fifth darkening falls from −6.52
to −3.24 codes and brightest-fifth darkening increases from −3.12 to −6.45.
The train window changes from −3.36 to −6.05, and Phoenix DSCF3091's path from
−1.41 to −5.09. This is improved targeting in those samples, not universally
stronger Highlights: Fuji DSCF2833's brightest fifth moves −7.47 under v2 versus
−4.11 under v3. Visual inspection agrees with modest changes at these increments.

The gallery's frame/context/edit selectors, same-edit profile switching,
comparison image loading and correction links were checked in the local browser;
no console errors or warnings were reported. It shows complete images beside
the measurements so numeric improvements can be rejected when their appearance
is undesirable.

Collateral effects and limits remain visible:

- No tested isolated Highlights/Shadows move has wrong-way luma changes larger
  than 1/65535. No frame is
  excluded. The trial has no measured black/near-white channel occupancy or
  newly neutralized eligible color samples under the recorded thresholds.
- Clean trial skin samples have own-baseline hue p95 at most 0.0152° and median
  relative-chroma change magnitude at most 0.0021%. Added color still has larger
  gamut-related changes: Phoenix leg Exposure +0.5 EV is −13.40% C/L with 55.56%
  of matched-Y reference rays outside gamut (v2: −13.70%, 55.81%). This is not a
  newly introduced v3 saturation failure.
- Saturated non-skin material is not perfectly unchanged. Fuji's red umbrella
  under Exposure +0.5 / Highlights −0.25 has own-baseline C/L change −0.50% in
  v3 versus −0.09% in v2, hue p95 0.398° versus 0.204°. Conversely, the modest-color
  Phoenix path has same-edit C/L +23.03% as the trial darkens it more and reduces
  display compression; nearby skin is +1.76%. Neither change is a standalone
  quality score.
- Local contrast is redistributed. Pro Image DSCF5809's leg under range
  compression has fine RMS ratios 0.681 (v2) and 0.823 (v3) against each baseline.
  But DSCF5800's arm under Exposure +0.5 / Highlights −0.25 falls from 0.997 to
  0.874; its same-edit ratio is 0.859, water 0.864. These are contrast/grain
  proxies, not recovered/lost detail. The trial has 80 fine and 760 coarse rows
  unavailable because eligible regions are too small.
- V3 Clean Invert baseline offsets span −0.022…+0.436 display codes for whole
  content and −0.948…+0.825 for named regions. Same-edit tables expose these;
  own-baseline response comparisons subtract them. Existing v2 settings remain
  exact: all 120 overlapping v2 photographic PNGs match the earlier run byte for
  byte, in addition to the five frozen preferred looks.

The trial still uses fixed global ranges. A stronger Contrast +0.25 combined
with only Shadows +0.1 / Highlights −0.1 darkens the darkest fifth in all six
frames. The existing over-white exposure response is unchanged. This is a
focused candidate for visual review, not a complete Camera Raw-like control
system or a new shipped default.

## Validation

The complete native release suite reports **711 tests, 14 explicit opt-in skips,
zero issues, 269.068s**. Local RAW fixtures are available. The skipped native
interaction benchmark was run separately above; unrelated export, roll and
performance cohorts were not enabled. The focused tone/legacy/marker run passes
41 tests; Python diagnostic discovery passes 18. Strict formatting passes for
the added Swift diagnostics/tests, and changed-file whitespace checks pass.

The expanded standalone comparator checks **4,398/4,398** cases: 4,002 GPU
comparisons within 2/255 and 396 intentional CPU routes, zero render failures.
The new explicit v3 family contributes 206 GPU comparisons (maximum 1/255) and
60 CPU routes, covering supported bases, small/extreme range controls, combined
grading and cropped density paths. Synthetic parity complements the 240
photographic comparisons; it does not replace visual acceptance.

Logs, exact v2 preservation comparisons and validation metadata are in
`dist/slider-response-validation-2026-09-24/`. The final native source and app/test
binary hashes match the completed interaction run. Source hashes identify this
uncommitted working-tree state, including pre-existing native work. No unrelated
working-tree changes, preference checkpoints or shipped defaults were replaced.

## Reproduction

Read [the color evaluation runbook](color-evaluation.md) and use fresh ignored
output directories. The tests do not install recipes or modify user settings.

```sh
.venv/bin/python native/diagnostics/color-study.py doctor \
  --workflow paired --output dist/slider-response-preflight-next
.venv/bin/python native/diagnostics/run-tone-response-study.py \
  --output dist/tone-response-next --metal
.venv/bin/python native/diagnostics/run-preview-interaction-study.py \
  --output dist/preview-interaction-next --repetitions 3 --events 120
.venv/bin/python -m unittest discover -s native/diagnostics -p 'test_*study.py'
```

Both runners record source/input/binary hashes and reject changing provenance
during a run. Do not compile another native product, edit native sources, or run
another performance workload concurrently. The photographic study uses frozen
archived scans with production Swift inversion/rendering. The interaction study
requires normal macOS graphics access and the private full-resolution RAW.
Neither standalone diagnostic is enabled by the ordinary unit-test command.

The focused trial uses explicit paired profiles and exports reviewable correction
documents without installing them:

```sh
.venv/bin/python native/diagnostics/run-tone-response-study.py \
  --output dist/tone-response-focused-next \
  --profiles native/diagnostics/tone-response-focused-profiles.json \
  --metal --correction-documents
```

The updated runner also rerenders all five preferred-look checkpoints and fails
if any original PNG hash changes. Version 3 is accepted only in explicit paired
trials with a matching version-2 profile. Same-edit measurements show both actual
v3-minus-v2 output and the difference in response after subtracting each baseline.
This matters because Clean Invert already has nonzero Highlights/Shadows.

Full-resolution export agreement, subjective acceptance, additional photographs,
Camera Raw slider sweeps, and physical input-to-display measurements require
separate validation. The artifacts here do not stand in for those checks.
