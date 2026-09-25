# Pro Image color separation and preferred FSC looks

**September 18 evidence; status checked September 19.** These scores and exports
predate the Film Base / LookRecipe migration. The current fitter still requires
`balanced-curves.json`, which a fresh native baseline no longer produces. The
[runbook](color-evaluation.md#current-compatibility) tracks this and the
clipboard contract gaps; this note does not establish a passing current run.

The user's feedback changes how the [initial study](camera-raw-color-study-2026-09-18.md)
should be judged. Fuji 400 Fresh `DSCF3115` Automatic is excellent to them; the
Phoenix II results on `DSCF3079` and `DSCF3086` are also good. Camera Raw matching
alone must not erase those successful FSC appearances. Conversely, the small
average errors of the Pro Image curve fits did not mean that their color felt right.

This follow-up provides two improved **per-frame trials using existing controls**.
The study itself made no changes to production processing, defaults, saved edits
or preset UI; later product changes are separate.

The subsequent [segmented skin RGB study](skin-rgb-study-2026-09-18.md) targets the
remaining red/green deficit in these exact outputs and applies the method across
six films, with explicit checks for changes to non-skin regions.

## Review

`dist/camera-raw-study/proimage-review.html` contains the Camera Raw references,
earlier Balanced + curves, and new color refinements for both Pro Image frames.
It includes a large same-size selector, copyable corrections and full-resolution
JPEGs. The earlier `basic-curves` result is also in the selector: that was the
first study's chosen recipe for `DSCF5809`, whereas `DSCF5800` used Balanced curves.
`proimage-color-comparison.jpg` is the compact overview.

The gallery's **Paste Corrections** instructions describe the old schema-1
workflow. The current app converts those files to public LookRecipe snapshots and
retains the destination inversion/calibration and dye mixing. Both displayed trials
depend on fitted `filmDyeMixing`, so a successful paste does not recreate the scored
result. Use the full parameter JSON for native study reproduction and validate
current applied settings/pixels before recommending app use. Framing is retained;
crop-dependent analysis can also change the rendering. These are per-frame recipes.

## What “faded” means in these examples

For `DSCF5800`, the reference and earlier Balanced curves already have similar
central lightness distributions: median L* 71.89 versus 71.98, and 90th percentile
87.00 versus 87.13. Medium-scale lightness structure is also similar. The important
remaining differences include weaker blue/cyan separation, less yellow in foliage,
and less red in some skin areas. Simply deepening shadows or boosting contrast
would not selectively repair those relationships.

The following values describe manually selected patches, measured after modest
blur in OpenCV Lab. They are not a calibrated Delta-E or perceptual quality score.
Patch coordinates and all measurements are saved in `proimage-color-results.json`.

| Frame / patch | Reference chroma | Earlier Balanced curves | Refined FSC |
|---|---:|---:|---:|
| 5800 water | 20.72 | 17.48 | 19.55 |
| 5800 blue shorts | 32.49 | 27.69 | 29.62 |
| 5800 greenery | 10.67 | 7.19 | 8.92 |
| 5809 blue shirt | 31.54 | 26.06 | 31.55 |

For the knee patch in 5800, median a* moves from 2.09 to 3.55, against 3.44 in the
reference, while L* stays near 71.5–71.9. In 5809's foliage, median b* moves from
−0.23 to +3.20 against +4.13 in the reference. These are specific color differences
that the initial per-channel median curves did not fully express.

Both XMPs use the same strong tone settings (Contrast +71, Highlights +57, Whites
+50), and grading luminance −70 in shadows / +38 in midtones. Global Saturation,
Vibrance and Clarity are zero. Those edits interact with the RAW balance, camera
profile and inversion curves; the slider numbers cannot be transferred directly
to FSC. The already fitted FSC curves largely reproduce the global lightness
distribution, so increasing contrast again is not the obvious remaining fix.

FSC also has more fine texture at the comparison scale: the high-frequency L*
residual RMS is about 20–22% higher than the reference. Different decoding,
resampling, sharpening and noise reduction are confounded here. This measurement
does not establish the cause, and the color refinements do not address it.

## Existing-control experiment

Retain the fitted channel curves, then coordinate-fit six `filmDyeMixing`
coefficients and seven photo adjustments. The native diagnostic renders through
`CPUPreviewPreparationCache` at the full 900-pixel proxy size so that changing the
fitting size does not change density analysis. The mixing matrix preserves neutral
inputs before subsequent curves; it can change channel relationships that three
independent curves cannot express by themselves.

The objective emphasizes R−G and B−G residuals with a smaller display-luma term.
It is not a perceptual metric. Bounds are ±0.5 for mixing; existing bounded photo
adjustment ranges are used. The content region expands to x=5–90%, y=10–93% to
include water, shorts and foliage excluded by the original central mask. It uses
the same 32-pixel spatial tile split (75% fitting, 25% withheld) and skips invalid
registration pixels. Every seventh fitting pixel contributes to optimization.

These are exploratory, within-frame fits following visual feedback. The spatial
tiles and a second starting point do not provide independent photograph validation.
The same images and references inform the study design.

| Frame / recipe | Original central test RGB MAE | Chroma residual MAE |
|---|---:|---:|
| 5800 earlier Balanced curves | 0.01353 | 0.01257 |
| 5800 color refinement | 0.00994 | 0.00728 |
| 5809 earlier Balanced curves | 0.02561 | 0.02409 |
| 5809 earlier basic + curves | 0.02175 | 0.01550 |
| 5809 color refinement from Balanced | 0.01511 | 0.01160 |

The displayed trial for 5800 is `color-separation`; 5809 is `color-balanced`.
The 5800 trial leaves exposure, brightness and contrast at zero; saturation becomes
+0.075, vibrance +0.005 and temperature −3.75. The 5809 trial likewise leaves those
three tone controls at zero; saturation is +0.0375, vibrance +0.1175 and tint +0.025.
Both keep Balanced's Highlights +0.08 / Shadows +0.04 and the prior channel curves.
Their six mixing coefficients are different: this is not one solved stock profile.

Fitting 5809 from the previous `basic-curves` result barely helped and slightly
worsened RGB error; that unsuccessful trial remains as `color-separation` for audit.
Transferring only 5800's mixing onto 5809's own fitted Balanced curves reduced
5809's chroma residual to 0.01376. This supports a shared direction of correction,
but the receiving frame still uses its own target-fitted curves, so it is not a
held-out-photo transfer result.

The remaining differences are visible. Some foliage and blues in 5800 remain weak;
5809's shirt can be too cyan and skin still differs. An optimization score is not
evidence that the user prefers either trial.

## Preserve successful looks; improve access to color

`color-preference-checkpoints.json` saves exact settings and PNG hashes for Fuji
3115 Automatic, and both Natural/Phoenix Darkroom candidates for Phoenix 3079 and
3086. The Phoenix feedback did not distinguish those two variants, so neither is
silently treated as the uniquely approved result. All five archived snapshots were
unchanged at the study checkpoint. Their stored hashes do not establish fresh-render
preservation after the product migration.

The excellent Fuji Automatic result uses Phoenix Darkroom internally. That is
evidence for keeping the rendering available beyond its stock name. A named-stock
classification issue and an aesthetically successful rendering can coexist.

The rework should preserve those looks while making three tasks independently
accessible: establishing scan/roll balance, shaping positive-image tone, and
steering color families. General hue/saturation/luminance controls and predictable
curve composition would make the kind of correction demonstrated here easier to
reach. Six matrix coefficients plus frame-fitted RGB curves are not a satisfactory
everyday workflow. New default calibration should be evaluated against both the
user's preferred FSC looks and the difficult Camera Raw references.

## Validation and reproduction

Both trials were exported through the native engine at **7752 × 5184**. After
resizing for comparison, reference RGB MAE is 0.01033 for 5800 and 0.01535 for 5809;
proxy-to-full MAE is 0.00322 and 0.00285. The color improvement survives export.
These CPU checks do not establish GPU preview parity or editing performance.

The study-time app clipboard parser accepted all **86** generated correction
documents; photo adjustments, all RGB curves and dye mixing survived, and framing
was preserved. Validation used an in-memory pasteboard, leaving the user's real
clipboard alone. Images were inspected locally; the browser UI was not exercised.

Use the maintained [runbook](color-evaluation.md) to inspect the ordered
reproduction steps:

```sh
.venv/bin/python native/diagnostics/color-study.py plan \
  --workflow proimage --full --output dist/proimage-study-next
```

Resolve the missing Balanced baseline and current clipboard contract before
starting a fresh complete run. Keep the historical output intact; it has no
guarded-run provenance.

`fit` recomputes all three native fits and the partial mixing-transfer trial.
`report` checks the preferred-image hashes and settings, exports corrections,
records central and expanded-region scores, and creates the review gallery.
Sources and settings are tracked; private image artifacts remain under ignored
`dist/`. A renderer change can invalidate the saved preference hashes and requires
explicit review of those appearances.
