# Segmented skin RGB and film-specific correction revisions

**September 18 evidence; status checked September 19.** The saved measurements
predate the Film Base / LookRecipe migration. Current study publication still
writes schema 1, while the named-preset probe requires schema 2. Migrating an old
correction in the app also omits its source inversion/calibration and dye mixing.
The [runbook](color-evaluation.md#current-compatibility) records these
open gaps; the historical validation below does not certify the current workflow.

The latest Pro Image outputs still lacked red relative to green in skin. Measuring
the same anatomical regions in the registered Camera Raw and FSC images confirms
the difference. A modest, tone-dependent red-curve revision improves both examples.
The final Pro Image recipes also refine channel mixing to protect blue fabric,
water and foliage. The main deficit is in shaded skin; some bright skin regions
were already close.

The study also produced **12 revised correction presets across six films**. These
used the study-time **Paste Corrections** and **Save Preset** controls. The current
app imports their public recipe fields but retains destination dye mixing and
inversion/calibration, so the copied result can differ from the scored image. They
are reference-conditioned recipes for this scan setup, not new stock calibrations. Shared correction tests did not support replacing bundled defaults.

## Review and artifacts

- `dist/camera-raw-study/skin-review.html`: Camera Raw / previous FSC / refined FSC /
  annotated regions; mean RGB, signed R−G bias, absolute errors and per-region tables.
- `skin-presets.json`: the historical schema-1 named document with 12 presets.
  Downloading it alone does not install it. Its schema currently disagrees with the
  probe, and app migration does not preserve every fitted study parameter.
- `skin-color-results.json`: all candidates, including unsuccessful experiments.
- `skin-review-results.json`: selected recipes and all underlying measurements.
- `skin-full-checks.json`: five full-resolution validation renders.
- [skin-profile-revisions.json](skin-profile-revisions.json): tracked parameter
  patches, named base recipes, base-parameter hashes and before/after skin metrics.
  Each patch belongs to its stated base recipe; it is not an interchangeable stock
  profile. The complete compatible correction documents are generated in `dist/`.

Framing is retained by Paste Corrections. Existing crop-dependent density analysis
can still change a match when applying it to a cropped image.

## Segmentation and mathematical comparison

`native/diagnostics/skin-regions.json` contains manually annotated polygons for
conservative visible-skin interiors on **15 frames from seven color stocks**. These
are measurement regions, not exhaustive person masks. Selection follows anatomy,
not an RGB or hue threshold: otherwise gray-green skin could be excluded from the
very measurement intended to diagnose it. Polygons are eroded by three pixels and
restricted to valid registration pixels. Overlays were inspected locally.

The samples include exposed legs, arms, hands, cheeks and necks. Dark scenes,
reflected cool light and different subjects remain in the data. Every reference
pixel is compared to the same location in the FSC render using the previous
SIFT/RANSAC alignment. A Gaussian blur with sigma 1.2 pixels reduces residual
grain and subpixel-registration sensitivity.

For normalized display RGB, the reported red/green bias is:

```
bias_RG = 255 × mean_skin[(R_FSC − G_FSC) − (R_reference − G_reference)]
MAE_RG  = 255 × mean_skin[abs((R_FSC − G_FSC) − (R_reference − G_reference))]
MAE_RGB = 255 × mean_skin,channel[abs(FSC − reference)]
```

Negative bias means less red relative to green. The signed mean can cancel opposing
errors, so the report also includes MAE and separate anatomical regions. These are
display-RGB measurements of creative reference images, not physical radiance,
colorimetric accuracy or a perceptual quality score.

| Pro Image | Reference mean RGB | Previous FSC mean RGB | Revised FSC mean RGB |
|---|---|---|---|
| DSCF5800 | 166.46 / 168.88 / 188.84 | 162.54 / 167.22 / 187.00 | 164.32 / 167.42 / 187.67 |
| DSCF5809 | 118.90 / 110.39 / 120.11 | 111.21 / 108.82 / 117.38 | 116.01 / 108.44 / 118.72 |

| Pro Image | R−G bias before → after | R−G MAE before → after | RGB MAE before → after |
|---|---:|---:|---:|
| DSCF5800 | −2.26 → −0.68 | 3.39 → 2.32 | 2.70 → 2.06 |
| DSCF5809 | −6.12 → −0.95 | 6.86 → 4.02 | 4.39 → 3.02 |

In 5800, the shaded far leg and rear arm initially have biases −5.01 and −6.40;
the revision brings them to +0.17 and −2.30. The brighter knee was already −0.32
and ends at +0.21. In 5809, the near leg moves from −9.61 to −3.37 and the cheek
from −11.87 to −5.78. The face therefore still differs; the image-wide mean does
not establish a perfect skin match. Some bright regions trade a little accuracy
for the larger improvement in shaded skin.

## How the existing FSC controls were fitted

First, try the six existing dye-mixing coefficients. Finite differences of native
FSC renders (±0.02 per coefficient) estimate the local RGB response. A bounded
quadratic fit emphasizes R−G and B−G, includes a display-luma term, and penalizes
changes outside the annotated skin. This helps several other films but can darken Pro Image
skin or worsen RGB error even while reducing the mean R−G error.

The next candidate adjusts the outputs of the existing
red-channel curve. Given an existing curve point output `y`, use three smooth
output-domain basis functions centered at `c = 0.25, 0.50, 0.75`:

```
b_c(y) = max(0, 1 − abs(y − c)/0.35)^2 × 4y(1 − y)
y_new  = clamp(y + sum_c a_c b_c(y), 0, 1)
```

Native renders with coefficients ±0.01 supply the Jacobian. Each coefficient is
bounded to ±0.08. The least-squares objective fits the measured skin R−G residual,
with a preservation penalty of 0.15 outside the skin masks and a small coefficient penalty.
Frame contributions are normalized by sample count. A monotonicity repair is
available if the point updates create a descending segment. Values exactly 0 or 1
stay unchanged. Skin masks guide calibration; the final rendering is an ordinary
FSC curve applied to the whole image, so similarly colored objects can change.

The red-only candidate leaves green and blue byte-identical. It reduces average
skin bias to −0.44 / −0.77, but worsens blue shorts in 5800: their reference RGB
error rises from 4.41 to 7.04. Optimizing only skin is not sufficient.

The final Pro Image fit jointly optimizes six mixing increments (bounded ±0.15)
and the three red-curve coefficients, with equal emphasis on RGB, R−G and B−G
residuals. Skin has total weight 1; each of three explicit non-skin control patches
has weight 0.25; preserving the current appearance outside annotated skin has
weight 0.15. The mixing/red coefficient penalties are 0.0005 / 0.00015. A bounded
coordinate solve stops when the largest coefficient update is below 1e−10, with
a 10,000-iteration cap and a convergence assertion. Full, 75% and 50% strengths
are rendered through FSC. The earlier lower-RGB-weight fit and an equal-anatomical-
region-weight fit are retained as experiments; the final recipe is
`skin-joint-rgb-100` for both frames.

Both final recipes change **filmDyeMixing and redCurveControlPoints** relative to
`color-separation` / `color-balanced`. The combined adjustment trades a little
red-only skin accuracy for better control of the rest of the photograph:

| Non-skin control patch | Previous RGB MAE | Final RGB MAE |
|---|---:|---:|
| 5800 water | 2.44 | 1.86 |
| 5800 blue shorts | 4.41 | 3.36 |
| 5800 greenery | 3.06 | 2.69 |
| 5809 blue shirt | 4.38 | 3.54 |
| 5809 tree | 2.40 | 2.67 |
| 5809 foliage | 2.41 | 2.64 |

Average RGB change outside the annotated skin is 1.34 and 2.08 levels. That region
excludes film rebate and a margin around annotations, but may contain unannotated
skin: it must not be interpreted as an exhaustive non-skin segmentation. The
separate water, fabric, tree and foliage patches above are explicit non-skin checks.

Fits use the previous 32-pixel spatial tile split: 75% training, 25% withheld.
On withheld skin tiles, RGB MAE falls **2.59 → 2.01** for 5800 and **4.72 → 3.17**
for 5809; R−G MAE falls **2.86 → 2.00** and **7.36 → 3.91**. These are exploratory
within-image checks, not independent skin or lighting validation. The same images
informed the masks, diagnosis and choice of model family.

## Applying the findings to other films

Candidate selection uses training skin RGB and R−G error, with a penalty for
changes outside sampled skin. It requires both training errors to improve and caps
that average RGB change at 4.1 levels. Pro Image additionally requires each explicit
non-skin patch's training RGB error to worsen by no more than 0.5 levels and includes
the mean control-patch error in candidate ranking. It does not use held-out target scores to
select a candidate. Candidate appearances were then inspected locally.

| Film / frame | Revision | Skin RGB MAE before → after |
|---|---|---:|
| CineStill 800T / 3247 | Small red-curve lift | 5.53 → 4.96 |
| Fuji 200 Expired / 3160 | Red-curve lift | 3.44 → 1.86 |
| Fuji 400 daylight / 2555 | Red-curve lift | 8.84 → 3.54 |
| Fuji 400 blue light / 3127 | Reduce excessive red with mixing | 19.54 → 4.20 |
| Gold 200 / 5740 | Reduce excessive red with mixing | 6.72 → 5.27 |
| Phoenix II / 3087 | Shared red-curve candidate | 11.58 → 7.84 |
| Phoenix II / 3088 | Mixing revision | 11.41 → 6.39 |
| Phoenix II / 3089 | Red-curve lift | 6.42 → 4.16 |
| Phoenix II / 3091 | Red-curve lift | 9.84 → 7.91 |
| Phoenix II / 3092 | Red-curve lift | 10.87 → 6.51 |

Lucky 5664 and 5675 already have mean R−G biases of −1.61 and −0.39. A common
red correction is not supported; those recipes remain unchanged. Fuji 3115
Automatic is an explicitly preferred appearance and is not fitted toward Camera
Raw. Its distinct rendering is preserved even though its reference error is larger.
The saved Phoenix 3079 / 3086 favorites also remain unchanged.

The stock-wide tests explain why these revisions should remain selectable recipes:

- A red-curve correction learned from Pro Image 5800 helps 5809, but the reverse
  transfer worsens 5800 (skin RGB MAE 2.70 → 3.84). A joint fit can hide that failure.
- The two Fuji lighting conditions need opposite corrections. A shared mixing
  increment learned on the daylight shot makes the blue-lit shot much worse.
- Shared Phoenix corrections often improve skin, but overshoot some frames and
  can move background colors by about five levels. Per-frame revisions perform
  better on several examples.
- Both shared Lucky correction families worsen at least one held-out frame.

These tests hold out the photograph from learning the **new correction component**.
The receiving frame retains its earlier target-fitted curves. They are therefore
conditional transfer tests, not evidence that a whole profile works on an unseen
scan. Some underlying inversion renderings also differ within a stock. Stock name
alone does not establish that one correction is appropriate.

## Validation and reproduction

Five native exports at **7752 × 5184** cover both Pro Image frames, Gold 5740, Fuji
2555 and Phoenix 3088. In the full-resolution Pro Image checks, skin R−G bias is
−0.79 and −0.84; RGB MAE is 2.56 and 3.06. Proxy/export sampling still changes the
numbers, especially for Gold. This study uses the production CPU renderer and
does not establish GPU preview parity or a new performance benchmark.

The study-time app clipboard parser accepted **194 generated correction documents**.
All 12 named presets also decoded through `NamedCorrectionPresetStore.Document`
and round-tripped their settings through the clipboard parser. Destination framing
was preserved. The probe uses an in-memory pasteboard. All five saved preference
snapshots retained their original image hashes and exact settings. These archived
checks have not been repeated against the current engine/app contracts. Source syntax,
gallery links and embedded JavaScript are checked separately; browser UI interaction
has not been exercised.

Use the [color evaluation runbook](color-evaluation.md) for maintained setup,
ordered stages, guarded execution and the current integration gaps. Inspect the
complete sequence without running it:

```sh
.venv/bin/python native/diagnostics/color-study.py plan \
  --workflow skin --full --output dist/skin-study-next
```

The cumulative workflow includes paired and Pro Image stages, every skin trial,
publication, the five full exports, gallery cross-links and the app-parser probe.
Resolve the missing Balanced baseline and publication/probe schema mismatch before
claiming a fresh complete run. Existing `dist/camera-raw-study` outputs are
historical and cannot be adopted by `--resume`.

The Python dependencies are NumPy, OpenCV and Pillow. The small bounded quadratic
mixing-only and red-only problems enumerate active constraint faces; joint fits use
bounded coordinate descent. SciPy is not required. `publish` now writes the
parameter-patch document inside the output directory. Recording it in
`docs/development/skin-profile-revisions.json` requires the explicit
`--revisions-output docs/development/skin-profile-revisions.json` option.
Private images remain in ignored
`dist/`; all pixel renderings come from FSC rather than an external color editor.
