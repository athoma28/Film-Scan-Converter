# Tone controls audit — September 22, 2026

**Historical audit of the version-1 tone path.** The defects measured here were
addressed for new edits by the [September 22 implementation](photographic-tone-controls-2026-09-22.md),
and the current source uses [version-4 tone controls](tone-range-separation-2026-09-24.md)
for new neutral edits. Saved version-1 edits retain their earlier rendering.
The findings below describe the audited source and its
fresh production renders: brightness used a fixed linear-light offset, contrast
moved the tonal endpoints substantially, exposure clipped at display white,
and a routine crop sent default color-negative edits through an expensive CPU
path. They are not claims about the current default response or crop latency.

This audit changes no production engine, app behavior, defaults, saved settings,
or preference checkpoints. It adds diagnostic tools and this record. The source
working tree already contained Film Base / LookRecipe, preview, and persistence
changes, which were preserved.

## Evidence and scope

- Release production Swift CPU operators evaluated on all 65,536 grayscale
  input codes. The isolated display-space probe uses Slide, with other controls
  neutral. Values below are actual semantic slider values, not drag fractions.
- 42 fresh CPU photographic renders: 14 settings each for Fuji 400
  `DSCF2833fix `, Pro Image `DSCF5800`, and Phoenix II `DSCF3079`. Inputs are the
  archived sensor-oriented 900px decoded scan buffers, with hashes recorded.
  The first two use explicit Color C-41 + Clean Invert; Phoenix uses Color
  cyan-mask + Clean Invert. These are current recipe baselines, not historical
  favorites or current app Automatic selections.
- Fresh performance probe on Fuji `DSCF2833.RAF`, using the app's full-sensor,
  one-pass preview decode, retained 2048px proxy, and production CPU preparation
  cache. Three warm samples per case, with every output pixel consumed by a
  Core Graphics draw. No RAW decode is included in render timings.
- Apple M4 Pro, macOS 15.7.9, Swift 6.1.2, LibRaw 0.22.2; working tree based on
  `c4ad5ba6a80741b47093f0fa6d9dc2d8dfa4c5f7`. Exact source, input, executable,
  and photographic output SHA-256s are in the local manifests.

Canonical local artifacts:
[`dist/tone-control-audit-2026-09-22-final/`](../../dist/tone-control-audit-2026-09-22-final/index.html),
including the [measured curves](../../dist/tone-control-audit-2026-09-22-final/tone-curves.png),
[ramp data](../../dist/tone-control-audit-2026-09-22-final/ramps.json),
[content metrics](../../dist/tone-control-audit-2026-09-22-final/content-metrics.json),
[timings](../../dist/tone-control-audit-2026-09-22-final/performance.json), and
[provenance](../../dist/tone-control-audit-2026-09-22-final/manifest.json).
These private/generated artifacts remain ignored and are not part of git.

## Findings

### P1 — Brightness directly creates a gray floor or clips shadows

[`RenderReadyLinearImage.swift`](../../native/FilmScanEngine/Sources/FilmScanEngine/RenderReadyLinearImage.swift)
lines 58–90 implement:

```text
RGB = RGB × 2^exposureEV
RGB = RGB + brightness × pivot
```

The post-display paths use `pivot = 0.18`. Brightness +0.5 therefore adds 0.09
linear light to every channel, including black. Brightness −0.5 subtracts 0.09,
pushing every lower channel value below zero. Later encoding clamps these values.
An equal addition also changes channel ratios, reducing shadow color separation
when increasing brightness; subtraction can clip channels independently.

| Ramp setting | Measured consequence, display values on a 0–255 scale |
|---|---|
| Brightness +0.5 | Pure black becomes **84.6**; the top 4.07% of input codes reach the near-white plateau |
| Brightness +1 | Pure black becomes **117.6** |
| Brightness −0.5 | The darkest **33.18%** of input codes become black |
| Brightness −1 | The darkest **46.14%** of input codes become black |

The user's old-Photoshop analogy matches this failure mechanism. Adobe describes
legacy Brightness/Contrast as a uniform pixel shift that can lose highlight and
shadow detail. FSC applies its offset in linear light, so this is a similarity
in behavior, not a claim of an identical Adobe algorithm.
[Adobe Brightness/Contrast documentation](https://helpx.adobe.com/photoshop/using/apply-brightness-contrast-adjustment.html).

### P1 — Contrast has no endpoint-preserving photographic response

The same file, lines 92–103, computes luminance `Y` and uses:

```text
Y' = pivot × (Y / pivot)^(2^contrast)
RGB' = RGB × Y' / Y
```

This preserves positive channel ratios before clipping, but its only fixed
positive anchor is the pivot. It neither limits its action to midtones nor
preserves display white. At Contrast −1, near-black 8/255 rises to **39.7/255**,
while white falls from 255 to **174.2**. Exact black stays black. The apparent
gray veil is the combination of lifted dark tones and dulled highlights; contrast
does not literally add a gray offset.

At Contrast +1, **31.69%** of a uniform encoded-gray ramp reaches the white
plateau, and some deep shadows quantize to black. Even +0.5 sends **19.92%** to
the white plateau. This is a missing toe/shoulder behavior, not merely an
aggressive slider range. A power curve can be useful as a specialized operator,
but it does not meet the expected behavior of a general photographic Contrast
control in this pipeline.

### P1 — Exposure loses useful headroom at display boundaries

The `2^EV` gain itself is correctly calibrated: +1 doubles linear values. The
problem is its position and the surrounding output mapping.

| Rendering path | What the tone controls receive |
|---|---|
| Current Color C-41 / cyan-mask density print | A bounded virtual-paper rendering, encoded to UInt16 sRGB and decoded to linear again |
| Calibrated color / monochrome | A bounded curve result, encoded to UInt16 before tone |
| Adjusted power law | Unclamped linear inversion output, with a different pivot, `1/24` |

`Processing.swift` lines 89–118 put calibrated/density rendering before the
semantic tone stage. `DensityPrintProcessing.encodeReflectance` lines 448–456
clamps reflectance and returns UInt16. The density print has its own paper toe
and shoulder, but these precede the user's tone edits. A subsequent floating
buffer cannot restore differences that a preceding stage already collapsed.
The calibrated reference curves also contain flat segments.

After tone, `Processing.swift` lines 831–859 convert back to bounded UInt16
display values **before** master/channel curves and grading. `linearToSRGB`
clamps its input to [0,1]. The adjusted power-law path likewise clamps during
its display transform. Hard channel clipping can therefore lose detail and
alter color before later controls can compensate.

On the isolated ramp, Exposure +1 sends **26.47%** of input codes to the white
plateau; +2 sends **46.29%**. With +2 followed by a curve whose maximum output
is 0.25, original values 160, 192, 224, and 255 all become **63.75**. Moving the
white plateau down does not recover its texture.

These are losses within a render, not edits to the source scan. Returning the
sliders to their original settings rerenders the source. The measurements do
not imply that every bright area in a baseline photograph was already clipped.

The differing pivots also mean the same brightness setting adds 4.32 times as
much linear light on post-display paths as on power law, before their different
display curves. Saved files using different inversion families cannot have one
consistent control feel under the current operators.

### P1 — Highlights can reverse tonal order, undermining recovery

The recovery control is relevant because it should help manage exposure.
`RenderReadyLinearImage.swift` lines 107–124 multiply by a smoothstep-weighted
gain. A smooth gain is not sufficient to make the resulting tone curve monotone.
With Highlights +1 and the ordinary 0.18 pivot:

```text
input linear gray 0.60 → 0.47556
input linear gray 0.90 → 0.29250
```

The brighter input becomes darker. The 16-bit display ramp has **10,766
descending adjacent green-channel steps** at this setting. The plot shows the
foldover. The GPU kernel contains the corresponding formula at
`StillPreviewRenderer.swift` lines 956–1004.

Positive Highlights also darkens in FSC, whereas ACR's positive direction
brightens. The Tone & Light panel has no independent Whites or Blacks controls.
Adobe describes Contrast as mainly affecting midtones, Highlights/Shadows as
including clipping-aware adjustments, and Whites/Blacks as separate endpoint
controls. Brightness is documented for its older process versions.
[Adobe Camera Raw tone documentation](https://helpx.adobe.com/camera-raw/desktop/using/make-color-tonal-adjustments-camera.html).

Adobe explicitly permits intentional clipping through endpoint controls. “Every
possible setting must remain attractive and unclipped” is therefore not a useful
absolute requirement. Preserving editable information, tonal order, and useful
separation over a broad range is a reasonable requirement. Adobe's documentation
does not expose its complete proprietary tone algorithm.

### P1 — Cropped default negatives have a large rendering latency cliff

`FilmBase.swift` selects density print for both current color-negative bases.
`StillPreviewRenderer.supports` lines 90–95 rejects **any non-nil manual crop**
for density print. Automatic crop, perspective, straighten, and the separate
measured-density pipeline also have CPU routing conditions.

`AppModel.scheduleRender` lines 4253–4267 only selects the 2048px drag proxy for
a supported GPU path. Rejected edits use the full source. The CPU branch at
lines 4424–4441 renders through `CPUPreviewPreparationCache`, without limiting
correction to the viewport or an interaction proxy. The cache preserves geometry
and density analysis, but it reruns inversion and subsequent pixel processing
for each tone edit.

| Fuji 40 MP, Color C-41 + Clean Invert | Warm samples, ms | Median |
|---|---:|---:|
| Uncropped Fit drag, 2048 × 1370 GPU proxy | 10.49, 10.21, 7.97 | **10.21 ms** |
| Uncropped full-source GPU refinement | 122.99, 102.45, 107.81 | **107.81 ms** |
| Manual-crop drag, full-source CPU; 80% width × 80% height retained | 2225.74, 2068.10, 1777.09 | **2068.10 ms** |

The crop path is about **203×** the proxy median in this bounded experiment.
This compares the actual resolution/routing policies, not CPU and GPU efficiency
at equal pixel counts. Three samples are not a p95 estimate. These direct
render-and-consume timings exclude app scheduling, native mouse input, screen
presentation, cold initialization, and ACR timing. They establish a severe path
worth fixing, not the exact latency of the user's currently running binary.

The rejection is intentional: cropped CPU density analysis and the GPU analysis
currently use different domains. Simply deleting the support guard would risk
changing the image. Shared analysis semantics and bounded fallback rendering
must be resolved together.

The scheduling code already has one active/latest pending request, a short
8 ms coalescing interval, background rendering, and asynchronous statistics
capped at 10 Hz during gestures. The `LivePreviewThrottle` 20 fps default is
not the scheduler for these still-image sliders. A long debounce is not the
main source finding here. Uncropped zoom/detail edits can also request full-source
work rather than the Fit proxy; their native interaction latency remains unmeasured.

## Photographic checks

The selected settings were inspected on all three frames. Reduced contrast lifts
the camera lens, street shadows and train interior while dimming their bright
areas. On Pro Image, negative brightness visibly clips the lens, clothing and
shaded rocks; positive exposure loses separation in the bright water/background.

Measurements use explicit rectangular content regions shown in yellow in the
gallery. They exclude film borders and holders. They count **channels**, not
the percentage of pixels that are completely black or white.

| Frame | Black channels, Brightness −0.5 | Near-white channels, Exposure +1 | Near-white channels, Contrast +0.5 | Encoded luma p99, baseline → Contrast −1 |
|---|---:|---:|---:|---:|
| Fuji DSCF2833 | 43.82% | 2.69% | 0.61% | 199.4 → 154.1 |
| Pro Image DSCF5800 | 19.81% | 27.42% | 19.97% | 242.9 → 172.1 |
| Phoenix DSCF3079 | 78.14% | 4.58% | 3.07% | 234.8 → 168.9 |

Baseline endpoint occupancy rounds to 0.00% for these content regions. The
encoded-luma statistic uses Rec.709 weights on display RGB; it is not scene
luminance, Delta E, or a skin-quality score. No segmented skin fitting or
comparison to Camera Raw pixels was performed. Brightness −0.5 is deliberately
a stress point, not a claim about every routine edit.

Black means code 0. Near-white means code >=65534: the CPU's truncated sRGB
encoding can put fully saturated values at 65534. Counting only code 65535
would falsely report no clipping. The initial `photographs.json` uses a generic
10% inset that includes holder on some frames; use `content-metrics.json` for
photographic claims. Uniform-ramp percentages describe input-code coverage,
not the distribution of light in an ordinary photograph.

## Recommended implementation order

1. **Specify a new versioned tone contract.** Preserve existing edits and frozen
   preferred looks. Define brightness as a midtone adjustment with black and
   highlight protection; contrast as a monotone response with controlled toe and
   shoulder; exposure as gain with useful headroom available to later controls.
   Make highlight direction and independent endpoint control explicit.
2. **Keep floating values through inversion and tone until the final display
   transform.** For density print, distinguish the editable positive/inversion
   stage from the bounded virtual-paper look. Avoid another encode/clamp/decode
   boundary between tone and later grading. Floating precision alone does not
   fix already-bounded input or an inappropriate curve.
3. **Replace the brightness/contrast/highlight operators as a coherent system.**
   Require tonal order across dense ramps, no unintended flat intervals at
   moderate settings, recoverable highlight differences before final output,
   and controlled color changes. Match neutral rendering under the chosen
   compatibility version. Then calibrate drag response on photographs.
4. **Make ordinary cropped edits stay responsive.** Share the correct analysis
   domain between CPU/GPU and retain reusable pre-tone data where appropriate.
   Provide bounded interaction for fallback cases, with exact refinement on
   release and memory accounting. Benchmark default density-print recipes with
   real crops, not just legacy calibrated-color GPU cases.
5. **Validate through both production renderers and the app.** Include current
   bases/looks, real skin and non-skin regions, unseen photographs, 100% output,
   preferred-look checkpoints, full-resolution export, and native event-to-screen
   timing. Keep aesthetic review separate from numerical ACR fitting.

The existing center-weighted drag mapping (`responseExponent: 1.6`) is secondary.
At 50% of the travel from center to an endpoint it produces a semantic magnitude
of about 0.330; semantic 0.5 is about 65% of that travel. Exposure uses a linear
−4…+4 EV mapping. Neither mapping repairs the operator curves.

## Verification, limitations, and reproduction

Preflight discovered 40 complete RAF/XMP/JPEG triplets and the same two incomplete
Lucky pairs (`DSCF5671`, `DSCF5676`). This focused audit selected three complete
color frames; it did not attempt the 40-frame fit workflow. The historical
recipe/schema integration gaps remain outside scope.

The production release build and probe completed. All 16 ramp variants, the
two targeted counterexamples, 42 photographic renders and three performance
cases completed in the canonical run. The first sandbox run could not access
Metal; a second used a three-pass source; both remain in separate directories
as preliminary evidence. The final run above uses normal Metal access and the
correct one-pass preview source. No production changes required a full-suite
rerun; no new end-to-end app acceptance is claimed.

The September 20 comparator recorded 3,613 GPU comparisons within 2/255 and
288 explicit CPU routes. Comparing its 156-entry source manifest now finds
changes only in AppModel, PerFileSettingsStore and its persistence tests;
the listed engine and renderer sources still match. That is prior synthetic
parity evidence, not a fresh photographic CPU/Metal comparison. The current
unit tests explicitly pin additive brightness and test contrast at just a few
interior luminances; they do not reject the endpoint failures or highlight
foldover demonstrated here.

From the repository root, with the runbook's local corpus/environment and normal
macOS graphics access, choose a **fresh** output:

```sh
.venv/bin/python native/diagnostics/color-study.py doctor \
  --workflow paired --output dist/tone-audit-next
.venv/bin/python native/diagnostics/run-tone-control-audit.py \
  --output dist/tone-audit-next
.venv/bin/python native/diagnostics/summarize-tone-control-audit.py \
  dist/tone-audit-next
```

The runner builds the production comparator product, links the diagnostic against
its engine/renderer objects, and records hashes before executing. It refuses an
already populated output. The summary tool requires NumPy, OpenCV and Matplotlib;
it measures saved UInt16 PNGs and plots recorded Swift samples, without emulating
the image engine. Its three content rectangles are specific to these 900px
sensor-oriented frames and need review if source geometry changes. Gallery
generation and local PNG/plot inspection completed; browser interaction was not
tested. No clipboard, preset publication, RAW modification, or full-resolution
image export was performed.
