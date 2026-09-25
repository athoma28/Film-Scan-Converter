# Camera Raw color and control study — September 18, 2026

**Historical results; status checked September 19.** The measurements below describe
the September 18 renderer and schema-1 correction workflow. The current working
tree separates Film Base from LookRecipe, changes fresh automatic initialization,
and migrates pasted corrections to schema-2 public recipe snapshots. The
[maintained runbook](color-evaluation.md#current-compatibility) lists
remaining diagnostic integration gaps. This note does not validate those changes.

FSC can get substantially closer to these Camera Raw references with its existing
renderer. The main obstacle is reaching the right channel response and tone balance
predictably. The automatic film/profile choice also disagrees with several stock
labels, although some of those renderings are user favorites. More named creative
presets alone would not address the control problems.

This was an offline study and a set of per-frame corrections; the study itself
made no change to app defaults, existing edits or presets. The subsequent product
migration is separate work.

**User feedback follow-up:** Fuji `DSCF3115` Automatic and the Phoenix II results
on `DSCF3079` / `DSCF3086` are looks to preserve. The initial Pro Image curve fits
still look faded. The [Pro Image follow-up](proimage-color-followup-2026-09-18.md)
measures the remaining color separation deficit and provides improved trials using
existing channel mixing. A low average RGB error did not settle the aesthetic issue.

## Review and use the results

The archived local artifact is `dist/camera-raw-study/index.html`. It contains all 40 pairs,
with columns for the Camera Raw reference, FSC's fresh automatic selection,
sliders-only fitting, and the best fitted FSC recipe. `comparison.jpg` is a compact
six-stock overview; `results.json` contains all scores and source paths.

The historical gallery supplies **Copy FSC corrections** buttons and JSON
downloads using schema-1 `CorrectionSettings` documents. The current app accepts
these through its legacy decoder, but captures only public LookRecipe settings: it
retains the destination film base, inversion/calibration and dye mixing as well as
framing. Pasting a file is therefore no longer sufficient to reproduce the scored
render. The plain per-variant parameter JSON remains the complete native-study
render input. These documents are not XMP imports.

At the time of the study, the recipes were checked through the actual `CorrectionSettingsClipboard`
parser with an in-memory pasteboard: **80 documents decoded successfully**, their
adjustments survived, and destination rotation and border crop were preserved.
The gallery button itself has not been browser-tested: automatic approval review
blocked the browser connector from inspecting private scan images. Local image
inspection and recipe/parser verification completed.

The fitted result is a starting point for the **matching frame**, not a universal
stock recipe. Full-frame fitting uses a 900-pixel scan proxy. Existing crop-dependent
density analysis and different preview/export sampling can change the result when
pasted into an already cropped image. Full-resolution checks are recorded below.

## Corpus and method

The measured corpus had **40 RAF/XMP/JPEG sets: 34 color and 6 monochrome**.
The September 19 read-only preflight still discovers 40 complete triplets.
The color references use Camera PROVIA/Standard in their XMPs. There are eight stock
folders. Exact-stem JPEGs take priority, then suffix variants; `cnegprofile` outputs
are excluded. Lucky `DSCF5671.xmp` and `DSCF5676.xmp` have no eligible JPEG partner
and are excluded. `DSCF5672.jpg` is not silently paired with `DSCF5671.RAF`.
Unpaired film scans and the nearby digital Tahoe photos are not scoring targets.

- Every RAF is decoded by production `rawTherapeeCameraScan`, not its embedded JPEG.
- References pass through FSC's standard image decoder. XMP is audited for settings
  and pairing; Adobe's processing is not reimplemented, and its numerical slider
  values are not treated as FSC values.
- SIFT/RANSAC homographies align the reference to the sensor-oriented FSC render,
  handling orientation, crop and export size. All 40 pairs passed: at least 68
  inliers per image, maximum median reprojection residual 0.51 reference pixels.
  Exact homographies and residuals are saved in each `alignment.json`.
- A conservative central 66% of width and height excludes the film rebate and
  sprockets. This also excludes genuine image content near the edges; the score
  does not guarantee good extrapolation there. Full-frame comparisons remain visible.
- Per-frame fits use 75% of spatial tiles. Recipe-family selection uses these same
  training tiles. The remaining 25% is scored. Basic-control fitting erodes the
  training mask before reducing to 192 pixels. This is within-image validation,
  not an independent photograph or roll test.
- Curves use conditional medians in 14 quantile bins and monotone pooling, then
  FSC's actual shape-preserving curve renderer. Depending on available samples,
  this produces fewer than 16 points per channel. There is no external image editor
  in the fitted rendering path.
- Basic sliders use a bounded coordinate search over exposure, brightness, contrast,
  highlights, shadows, temperature, tint, saturation and vibrance. Two starting
  renderings are tried. This is a useful attainable fit, not a proven global optimum.
  Color wheels, dye-matrix tuning and arbitrary local edits are not optimized.
- Candidate starting renderings include Natural, Balanced, Legacy, relevant stock
  choices, neutral density inversion, and the existing simple-complement mode.
  A second pass fits curves on the better sliders-only render. Final selection is
  on training tiles only.
- The automatic baseline uses the production classifier on a 256-pixel analysis
  image with **no saved settings and no same-roll hint**. It is a CPU study of that
  path, not a capture of the running app. Saved edits or a roll hint can differ.
- MAE is the mean absolute difference of normalized display RGB components after
  a 1.2-pixel Gaussian blur to reduce grain/alignment sensitivity. The reported
  chroma residual subtracts the weighted display-RGB luma residual. Neither metric
  is Delta-E. The targets are the user's finished creative edits, not colorimetric
  ground truth. Metrics cannot replace visual judgment about skin and rare colors.

## Attainable matches

Lower MAE is closer to the supplied Camera Raw JPEG. Values below are frame means
within each stock; the final column can contain both basic adjustments and curves.

| Stock | Pairs | Fresh automatic | Basic sliders | Fitted FSC recipe |
|---|---:|---:|---:|---:|
| CineStill 800T | 2 | 0.124 | 0.021 | 0.011 |
| Fuji 200 Expired | 1 | 0.220 | 0.017 | 0.010 |
| Fuji 400 Fresh | 11 | 0.150 | 0.043 | 0.017 |
| Gold 200 | 2 | 0.111 | 0.033 | 0.018 |
| Harman Phoenix II | 12 | 0.140 | 0.029 | 0.013 |
| Lucky C200 | 4 | 0.213 | 0.033 | 0.017 |
| Pro Image | 2 | 0.118 | 0.031 | 0.018 |
| Shanghai GP3 | 6 | 0.148 | 0.014 | 0.009 |

Across 34 color frames, the frame mean is **0.150 → 0.033 → 0.015**. Giving each
color stock equal weight instead yields **0.154 → 0.029 → 0.015**. This substantial
improvement says that FSC's existing controls can express much of the desired
appearance once tuned to a reference. It does not say that an automatic recipe
will make a new scan 90% more accurate.

The Gold `DSCF5740` example makes the tradeoff visible. Natural is flat and blue-gray;
Balanced is brighter, with warm skin and paler sky than the reference. A successful
basic fit starts at Balanced and requires temperature −87.5, tint +0.325, vibrance
+1, exposure −0.5 EV and several tone adjustments. The curve refinement gets closer.
Gold `DSCF5786` reaches the temperature limit of −100 and vibrance +1. The control
range is doing substantial repair of the starting rendering before creative editing.
These are FSC values, not Adobe temperature/tint or exposure equivalents.

The Pro Image examples need open highlights with much firmer shadows. The Lucky
examples span hard daylight and night scenes; their fitted tone and balance settings
are very different. The old Lucky daylight recipe is not an adequate stock-wide
solution. Residual differences remain in skin, olive/brown clothing, cyan/blue
separation and low-sample extremes. Colored borders in some fitted renders are
an explicit consequence of fitting the image area; normal cropping removes the
rebate, but those borders are not included in the accuracy claim.

## A recipe is not a stock profile

As a separate experiment, fit shared RGB curves from all *other* frames of the same
stock, then apply them to the held-out frame. Use fixed Natural and simple-inversion
families independently; do not choose a family using the held-out target. This
measures transfer of these particular curve models, not the limit of all possible
film calibration methods.

| Stock | Natural unchanged | Natural + other-frame curves | Simple + other-frame curves |
|---|---:|---:|---:|
| Fuji 400 Fresh | 0.134 | 0.118 | 0.149 |
| Harman Phoenix II | 0.172 | 0.067 | 0.078 |
| Lucky C200 | 0.169 | 0.135 | 0.081 |
| Shanghai GP3 | 0.186 | 0.231 | — |

The transfer scores use the same central test region of the held-out frame for
comparability. The held-out frame contributes no fitting samples. The cohorts
are small and may share rolls or lighting; this is not independent roll validation.
Gold, Pro Image, CineStill and expired Fuji have too few frames for this study's
minimum three-frame transfer protocol. The much lower per-frame fitting errors
must not be used as evidence for promoting a new generic default.

## Concrete control and default findings

These are September 18 findings. In particular, the named-stock classifier and
old preset UI described here are not the current Film Base / LookRecipe workflow.
Curve composition, saturation and crop-related concerns still need their own
validation; the historical probe is not a test run against today's working tree.

1. **Mask color is being used to guess a named stock.** Fresh classification chooses
   Phoenix II Darkroom for seven of eleven Fuji 400 frames, three of four Lucky
   frames, one Pro Image frame, the expired Fuji frame, and all six GP3 scans.
   It also classifies CineStill `DSCF3277`, Fuji `DSCF3127` and Lucky `DSCF5702` as
   slides. The study has no weak roll prior; the app can behave differently with one.
   Even so, scan color is not adequate evidence for a named-stock selection here.
2. **Master and channel curves do not compose.** In CPU and GPU LUT construction,
   an enabled channel curve replaces that channel's master curve. A production
   probe sends BGR `[20000, 20000, 20000]` through a half-output master curve:
   `[10000, 10000, 10000]`. Enabling an identity red curve changes the result to
   `[10000, 10000, 20000]`. Merely enabling the red curve changes the image even
   before moving a point. The XMPs repeatedly combine a descending master
   inversion curve with nontrivial per-channel curves.
3. **The saturation range is unexpectedly restrained.** The minimum uses
   `exp2(-1)`, further weakened by highlight/gamut protection. On a representative
   linear BGR `[0.1, 0.2, 0.6]`, minimum saturation retains **59.7%** of the
   original luminance-relative channel deviation. The slider cannot fully
   desaturate this sample. Tone-dependent protection also changes its sensitivity.
4. **Scan balance and positive-image grading are different operations.** For Natural
   and density-print paths, temperature/tint are applied after inversion, as
   protected opponent-chroma shifts. They are not adjustable RAW white balance or
   film-base neutralization. The supplied XMPs use temperatures from 3400–8800 K,
   tints −76…+3, individual RGB curves and grading. Copying those numbers to FSC
   cannot reproduce the processing.
5. **Tone controls are incomplete relative to the reference edits.** The color XMPs
   use Whites from −29…+53 and Blacks from −89…+44. FSC provides neither independent
   endpoint control in its primary tone panel. Many references also use large
   shadow/midtone grading-luminance edits. Saturation is zero in every color XMP:
   a global saturation boost alone is not the intended rendering recipe.
6. **Selective hue edits are real evidence, not speculative feature requests.**
   Lucky uses different red and orange hue moves; Phoenix uses green/aqua/blue
   moves; CineStill `DSCF3247` uses strong red/orange/yellow corrections. FSC's
   special foliage correction is not a general replacement for editable hue
   families. Split toning appears extensively too.
7. **Natural/Darkroom clamp before later controls.** These inversion stages return
   `UInt16Image` before the semantic adjustment seam. Later exposure/highlight
   edits cannot restore information already clipped by those stages. The adjusted
   power-law path differs. A float buffer after a clipped inversion alone does not
   solve highlight recovery.
8. **Cropping can change the grade.** With the fitted density recipes unchanged,
   cropping 10% from each edge changes the same retained pixels by MAE 0.0111
   for Gold `DSCF5740`, 0.0138 for Pro Image `DSCF5800`, and **0.0466** for Lucky
   `DSCF5664`. Density analysis is rerun after geometry, changing its statistical
   basis. Lucky night `DSCF5702` uses simple inversion and is byte-identical on
   the retained pixels. This is a CPU comparison of rendering-before-crop versus
   cropping-before-render, with exact matching pixel coordinates; it is not a
   registration artifact. See `crop-sensitivity.json`.

Implementation references: `FilmNegativeProcessing.classifyFilmScan`,
`FilmProcessing.applyDisplayPointAdjustments`, `StillPreviewRenderer`'s curve LUT,
`ProtectedColorAdjustment.apply`, and `ContentView`'s Tone & Light / Color & Balance.
`control-probe.json` records the measured curve and saturation behavior.

## Rework order supported by this evidence

1. Separate declared film identity from a recommended rendering. Keep the Phoenix
   Darkroom appearance available, including on Fuji: the user explicitly likes
   that result on `DSCF3115`. A pleasing rendering is not evidence for a stock
   identification. Preserve the preferred examples when revising defaults.
2. Separate reusable scan/roll calibration from per-photo grading: film base,
   channel density offsets and channel contrast should be editable and lockable.
   A scene's color distribution should not silently redefine the roll's balance.
   Lock the analysis region once the balance is set, so changing the composition
   does not silently re-grade the photo.
3. Introduce versioned curve composition with an explicitly defined order. Preserve
   old saved appearances; add regression coverage for master + all RGB combinations
   and CPU/GPU agreement. An identity channel curve should not disable master tone.
4. Give saturation a useful full range, and separate optional protection from the
   main adjustment. Add true black/white endpoint controls and predictable positive
   exposure/highlight controls. Keep inversion output floating point until the
   final display stage.
5. Add general hue-family hue/saturation/luminance controls and independent grading
   luminance/blending. Keep named looks as recipes on top of these controls.
6. Refit defaults only after those controls are stable, using stock-balanced tests
   and whole held-out rolls. Keep these 40 pairs as visual regression targets,
   including the difficult night scenes, skin and saturated sky.

The curve fits already run as ordinary FSC LUTs. They do not require a new RAW
decode for each adjustment. This study provides no measured performance claim
for the proposed rework, which still needs preview/export benchmarks.

## Reproduce

Use the [color evaluation runbook](color-evaluation.md) for maintained setup,
ordered stages and the current migration gaps. The read-only entry points are:

```sh
.venv/bin/python native/diagnostics/color-study.py doctor \
  --workflow paired --output dist/paired-study-next
.venv/bin/python native/diagnostics/color-study.py plan \
  --workflow paired --full --output dist/paired-study-next
```

After reconciling current recipe and clipboard contracts, the runbook's `run`
workflow builds the production renderer, runs the fits and full/crop cohorts,
and validates generated documents. Use a fresh output directory; the historical
`dist/camera-raw-study` has no runner provenance and cannot be resumed. Low-level
scripts reuse cached scans and alignment and do not detect source/data changes.
Generated images and full parameter JSON stay in ignored `dist/`; no presets are
installed into the user's Application Support directory by these tools.

## Full-resolution validation

In the original study, four recipes were rendered from the RAFs at **7752 × 5184**, with the app's
256-pixel export median analysis and the production CPU renderer. The JPEGs are
linked from their gallery rows. These exports are uncropped and retain the scan
orientation. Scores below compare the 900-pixel reduction of the full render to
the aligned reference using the same held-out regions.

| Frame | Proxy fit MAE | Full render MAE | Proxy/full difference |
|---|---:|---:|---:|
| Gold DSCF5740 | 0.0166 | 0.0198 | 0.0106 |
| Pro Image DSCF5800 | 0.0135 | 0.0142 | 0.0030 |
| Lucky DSCF5664 | 0.0098 | 0.0101 | 0.0021 |
| Lucky DSCF5702 | 0.0125 | 0.0124 | 0.0013 |

The match persists at full resolution, with a visible sampling/analysis difference
in the Gold image. Grain/detail rendering is also different from Camera Raw; this
study has not matched Adobe's denoising, sharpening, texture or local contrast.
Decode + render + JPEG export took 5.7–9.5 seconds for these four local runs;
these are observations, not a controlled performance comparison. GPU equality of
these particular recipes was not tested. No production renderer changed in this
study, so the measurements do not certify a new pipeline's CPU/GPU parity.

The runner's `--full` includes these four historical frame selections; `crop` is
always included. Neither selection is a full-corpus export or current-app parity
claim. Fresh settings need their own full-resolution check.
