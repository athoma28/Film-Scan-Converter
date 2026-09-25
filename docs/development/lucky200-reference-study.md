# Lucky 200 daylight reference study

**Historical tuning record; status checked September 19, 2026.** The current app
uses Film Base plus public LookRecipe settings. It no longer offers the old
`lucky_200_daylight` factory preset described below. The current **Foliage** recipe
uses warm-hue recovery 0.55 with a different public-slider snapshot, leaving the
destination film base/invert intact. It is not a rename or pixel-equivalent version
of this historical recipe.

The native diagnostic and Python gallery now agree on `cleanInvert` / `foliage`
IDs. A fresh current-recipe gallery is recorded in the
[September 25 follow-through](roadmap-follow-through-2026-09-25.md). It does not
reproduce the historical recipe or validate it on an independent cohort. See the
[color runbook](color-evaluation.md#current-compatibility).

The former **Lucky 200** color preset was tuned against five scans in `sample-raw/luckyc200`
and five nearby digital Fuji RAFs in `tahoe test digital photos`. The digital
photographs show the same Tahoe setting, with similar summer foliage, pavement,
granite, backlight, and lake color, but not identical scenes. They provide material
and illumination guidance, not pixel-aligned or colorimetric ground truth.

## Evidence and scope

Scans: DSCF3790, DSCF3799, DSCF3802, DSCF3811, DSCF3816 copy 2.
Digital references: DSCF3444, DSCF3500, DSCF3515, DSCF3550, DSCF3560.

Scans are decoded through the production `rawTherapeeCameraScan` path and reduced
to 1200 pixels for review. Digital positives are decoded independently with
LibRaw/rawpy 0.24.0, camera white balance, sRGB primaries and transfer, half-size
demosaic, and auto brightness. They are never inverted. No Fuji film simulation
or channel edit is applied. The digital camera-WB multipliers are consistently
606/302/491; the scan files use 611/302/482. Embedded JPEGs were checked for scene
interpretation, but the review's reference column is rendered from RAW.

Three scans initially guided the hue trials; DSCF3802 and DSCF3816 exposed their
failure. All five subsequently informed the final recipe. There is **no independent
held-out accuracy claim**, and no MAE/Delta-E score between unrelated scenes.
This preset is specific to the supplied daylight roll and scan setup. Additional
rolls, capture setups, artificial lighting, and unusual orange subjects need review.

## Historical recipe

1. A tuned `lucky_200_daylight` density profile uses a shared neutral response
   anchored to green's per-frame density range. Its log10 neutral reference is
   RGB `[-1.22, -1.30, -1.05]`, with unit slopes. Only the differences (+0.08 red,
   +0.25 blue relative to green) matter. These were selected from neutral-looking
   pavement and granite, checked against the nearby digital materials. The raw
   sun-pavement patch in DSCF3802 is approximately `[-1.149, -1.210, -0.919]`;
   sun-granite in DSCF3811 is approximately `[-1.415, -1.538, -1.389]`. A single
   offset is a compromise across illumination and material; these are not gray-card
   measurements. Unit slopes avoid overfitting their different lighting.
2. Identity dye unmixing and neutral paper avoid inventing a measured dye matrix.
   Per-frame exposure/contrast analysis remains active. Automatic cast cleanup
   starts at zero so it does not undo the roll's neutral prior.
3. A smooth warm-hue recovery at 65% moves residual copper foliage toward olive.
   The mask fades in from 18–34 degrees and out from 70–160 degrees in display-sRGB
   hue. Chroma and highlight protection exclude pale surfaces and bright extremes;
   affected saturation is reduced, and linear Rec.2020 luminance is conserved.
   This is a color-family operation, **not** semantic foliage/skin recognition.
   Similarly colored wood, dry vegetation, or skin can move. **Foliage Recovery**
   under the then-current **Shape the Preset** panel controlled its strength.
4. Highlights 0.08, shadows 0.04, saturation -0.06, and vibrance 0.04 complete the
   recipe. Exposure and framing are preserved on application.

Broad channel mixing was rejected because green recovery made blue water purple.
Hue-only recovery was rejected because the worst scans retained orange shrubs
while some sand became green. The shared neutral response fixes that underlying
frame-to-frame balance before the smaller selective correction.

## Descriptive checks

At 1200 pixels, fixed material patches show the following median hue movements
(Balanced → Lucky 200). These describe the output, not reference matching error:

| Material | Hue before → after | Other observation |
|---|---|---|
| DSCF3790 foliage | 31.9° → 73.0° | Copper toward olive |
| DSCF3802 sage | 21.9° → 53.9° | Saturation 0.69 → 0.35 |
| DSCF3811 shrubs | 25.3° → 48.8° | Less orange; mixed dry vegetation remains |
| DSCF3816 foreground shrubs | 15.2° → 53.8° | Red-orange removed across the shoreline |
| DSCF3811 skin | 15.0° → 15.5° | Warm hue retained, less saturated |
| DSCF3802 pavement | — | Saturation 0.58 → 0.15 |

For context, the digital RAW material patches have median chromatic hues of
57.9° (DSCF3500 broadleaf shrub), 68.6° (DSCF3550 pine), and 52.9°
(DSCF3550 sage). Their median saturation is 0.17–0.23; the preset retains more
film color. These are different plants/viewpoints, not matched measurement pairs.

The sun-granite patch remains low-chroma but moves cooler; shaded pavement and
water also become bluer. This is a tuned starting point, not exact reconstruction.
All five pre-existing Balanced review JPEGs were byte-identical after that
historical change. No fresh comparison of the current Foliage recipe is recorded here.

## Current diagnostic entry point and remaining work

From the repository root, generate current Clean Invert / Foliage images into a
new directory:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/fsc-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/fsc-swiftpm-cache \
swift run --disable-sandbox -c release --package-path native/FilmScanEngine \
  FilmScanLookbook /tmp/lucky-current-review --lucky-study
```

`LuckyReferenceStudy.swift` enumerates every top-level Lucky RAF, not just the
five historical scans above. Keep this output separate from the old review. The Python builder consumes the current IDs directly:

```sh
.venv/bin/python native/diagnostics/lucky200-reference-study.py \
  /tmp/lucky-current-review --output dist/lucky-current-reference-review
```

Do not present this as reproduction of the historical recipe's numbers.
The historical gallery remains `dist/lucky200-reference-study/index.html`, with
`before-after.jpg` and `patch-report.json`; it requires the private local artifacts.
The digital-reference builder also needs `rawpy`, which is not part of the paired
study's `requirements-color-study.txt`.

For the current synthetic and app recipe contracts, the targeted command is:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/fsc-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/fsc-swiftpm-cache \
swift test --disable-sandbox -c release --package-path native/FilmScanEngine \
  --no-parallel \
  --filter 'Lucky200PresetTests|LookRecipe|PhotoAdjustmentParametersTests|ProtectedColorAdjustment|DensityPrint'
```

`Lucky200PresetTests` now contains four synthetic tests for warm-hue exclusions,
luminance preservation, old JSON and neutral-response behavior. The old
`RUN_LUCKY200_REFERENCE_TESTS` opt-in is absent from current source; setting it no
longer runs the historical five-RAW comparison. LookRecipe tests cover the current
recipe and app behavior separately. Neither command above was run during this
documentation audit.

The original implementation recorded **47 targeted passing tests**, including five
real-RAW CPU/GPU comparisons within 2/255, plus app/archive bundle and signature
checks. Its parallel run took 94.5 seconds and GPU-only checks 17.8 seconds. Those
are historical results for the old recipe/build, not current regression totals,
release evidence or current Foliage parity. Fresh real-image, export and CPU/Metal
validation are still needed to make those claims for today's recipe.
