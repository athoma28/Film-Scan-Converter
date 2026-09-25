# Immediate workflow priorities and perspective framing

Artifact dates use UTC (September 24 PDT). This records local source work on top of `fc63454` and the existing uncommitted
Film Base, tone, preview and optimization changes. Environment: Apple M4 Pro,
48 GiB RAM, macOS 15.7.9, Swift 6.1.2, LibRaw 0.22.2; Python 3.12.7,
NumPy 2.2.1, OpenCV 4.10 and Pillow 11.1. Private scans and generated artifacts
remain under ignored `sample-raw/` and `dist/`. No defaults, factory recipes or
preference-ledger entries were replaced.

## Application changes

- Copying a look to an unseen destination now persists its pending intent.
  Classification runs when pixels become available, then reapplies the copied
  public controls, including Cast Cleanup and Color Separation. Saved Original
  frames retain their explicit meaning. Preview, export and contact sheets share
  the classifier; Undo/Redo and relaunch preserve deferred initialization.
- Selection changes retain one render drain while an existing detached worker
  finishes. Stale results are rejected and only the latest pending request runs.
- **Load RAW Preview** goes directly to full-sensor detail, including during an
  inspect upgrade. Cooperative cancellation releases the shared decoder gate.
- Perspective has an optional **Frame Ratio** that restores known proportions
  before orientation/straightening, preserving the estimated pixel area. Automatic
  retains the previous edge-length estimate and old saved crops decode unchanged.
  The grid now projects equal output divisions through the same homography as
  the warp. The shaded border shows the actual inset framing. Corner drags retain
  their initial grab offset; snapping uses screen distances on rectangular scans.
  Arrow keys move the selected corner one source pixel, Shift ten; Option keeps
  drags free. Reticles/loupe strokes scale with zoom. Reset Corners retains the
  ratio in one undo step. Changing perspective invalidates a dependent manual crop.

The focused workflow run passed 16 tests, and the focused geometry run passed
51 tests, including actual app preview/TIFF pixel comparisons, history, ratio
orientation, persistence, all display orientations and zoom-coordinate helpers.
These are automated tests, not a new hands-on pointer assessment of the packaged app.

## Reproducible color workflow

`dist/roadmap-color-v2-2026-09-25/` completed all 29 cumulative skin-study stages,
the actual app-parser probe and the final source/input integrity check. The
runner pins its own renderer; SHA-256:
`7a93631075b97ff9ef40ed44432fc09974a7c5251a840c49664b0033e0cd1f4d`.
Its manifest records source/input hashes, environment, command order and logs.
An earlier integrated attempt was stopped because another build replaced its
shared executable; it is retained as interrupted evidence. The isolated renderer
and completion-time integrity check fix that reproducibility gap.

The migration fits public controls on canonical Film Bases and exports native
schema-2 recipes. Pro Image uses Cast Cleanup/Color Separation plus photo controls;
skin derivatives use temperature, tint, saturation, vibrance and those two density
controls, followed by bounded red-curve/joint trials. Private dye calibration is
retained. Selection uses training metrics, including background/control guards;
held-out scores cannot select recipes.

All **40 pairs across eight stocks** registered: minimum 23 inliers, minimum
central coverage 0.435, maximum median residual 0.688 px. Two incomplete pairs
remain excluded: Lucky DSCF5671 and DSCF5676. Mask/registration review covered all
15 annotated skin frames, including individual faces, arms and legs. Masks are
conservative sampled interiors, not exhaustive segmentation.

All **five frozen preferences matched their exact PNG hashes** using freshly
decoded scans and recorded historical medians. The two Phoenix stock looks need
those historical medians, which are intentionally absent from parameter JSON.
They are separate from current Automatic classification. The ledger was unchanged.
The probe reproduced **254 published recipes with exact applied parameters and
CPU pixels**, decoded **13 named presets**, and separately checked destination
framing/calibration preservation. Applying a recipe to a different Film Base or
private calibration intentionally produces different pixels.

Paired held-out RGB MAE, in 8-bit display levels after the documented blur:

| Stock | Pairs | Canonical base | Selected per-frame fit |
|---|---:|---:|---:|
| CineStill 800T | 2 | 48.11 | 2.75 |
| Expired Fuji 200 | 1 | 54.60 | 2.65 |
| Fresh Fuji 400 | 11 | 36.03 | 4.60 |
| Gold 200 | 2 | 49.68 | 4.34 |
| Phoenix II | 12 | 36.11 | 3.34 |
| Lucky 200 | 4 | 42.97 | 4.65 |
| Pro Image | 2 | 31.96 | 4.43 |
| Shanghai GP3 | 6 | 47.35 | 3.11 |

These are fits to edited Camera Raw references, not stock accuracy or evidence
for changing defaults. The split withholds spatial tiles within each photograph;
those tiles are not independent photos. Exact baseline/selected IDs, parameters,
train/test RGB, luma and chroma scores are in `results.json`.

Skin selection accepted 13 changes, retained Phoenix DSCF3089's base, and retained
the user-preferred Fuji DSCF3115 appearance despite its greater reference error.
Representative training / held-out skin RGB MAE:

| Frame | Selected recipe | Training before → after | Held-out before → after |
|---|---|---:|---:|
| Fuji DSCF2555 | skin-red | 6.83 → 4.38 | 6.87 → 4.49 |
| Fuji DSCF3127 | skin-frame | 18.69 → 8.89 | 18.75 → 8.87 |
| Gold DSCF5740 | skin-frame | 6.33 → 5.80 | 5.37 → 5.33 |
| Phoenix DSCF3088 | skin-red | 7.43 → 5.75 | 7.34 → 5.75 |
| Lucky DSCF5675 | skin-stock | 11.99 → 11.11 | 12.93 → 12.82 |
| Pro Image DSCF5800 | skin-joint-rgb-75 | 3.26 → 2.54 | 3.19 → 2.43 |
| Pro Image DSCF5809 | skin-joint-100 | 4.63 → 3.31 | 5.05 → 3.46 |

Improvements are not uniform. Gold cheek/neck held-out error increases
1.98→2.25 / 2.16→2.79; Lucky DSCF5675's front cheek, knee and hand worsen
6.05→6.47, 14.14→15.32 and 5.92→7.06. Pro Image DSCF5809's crossed-leg region
worsens 1.96→2.14. Its tree/foliage control patches worsen 2.46→3.46 /
2.03→2.99, while shirt error improves 7.66→5.93. DSCF5800's water/greenery
errors rise 2.71→2.91 / 1.00→1.26 while shorts improve 5.25→3.42.

Failed conditional transfers remain in the report: Fuji DSCF2555 skin error
6.87→17.27 for the held-out public-color increment and 6.87→12.12 for the
held-out red increment; further failures include Fuji DSCF3127, Phoenix
DSCF3088/3089, Lucky DSCF5664 and Pro Image DSCF5800. The receiving bases were
already reference-fitted: these experiments do not validate entire profiles on
unseen photos. Inspect `skin-review-results.json`, `skin-color-results.json`,
individual region crops and control-patch tables before choosing a candidate.

Eleven study JPEG exports were rendered at **7752 × 5184**: four paired fits,
two Pro Image trials and five exact selected skin recipes (Fuji DSCF2555, Gold
DSCF5740, Phoenix DSCF3088, Pro Image DSCF5800/5809). The selected skin checks bind
parameter SHA-256s. Their proxy-to-full RGB MAE is 0.82–2.47 display levels on
the declared skin/background mask. This does not verify full exports of all 13
published candidates. The full-resolution TIFF checks below cover a separate
six-photo version-4 control cohort.

The current Lucky native renders and Python gallery also run together using
Clean Invert/Foliage IDs. `dist/roadmap-lucky-review-2026-09-25/` compares five
scans with five unpaired digital references; its material statistics are descriptive,
not pixel-aligned errors or reproduction of the historical Lucky preset.

## Photographic preview and output evidence

`dist/roadmap-tone-metal-2026-09-25/` completed **204 same-source CPU/Metal
comparisons**, across six photos, tone versions 2/4 and 17 variants, with zero
failures and a maximum difference of **1/255**. All five frozen preferences
matched again. The recorded scalar response still includes small nonmonotonic
positive-exposure changes for inputs above scene-linear 1; this study did not
change the existing tone response or silently remove those samples.

`PhotographicExportTests` explicitly ran on Fuji DSCF2833/2892, Pro Image
DSCF5800/5809 and Phoenix DSCF3079/3091. Each case edited all version-4 tone/grading
levels through the app, waited for the full preview, and exported an LZW TIFF.
All six app/Metal previews stayed within 1/255 of the same-source CPU result.
All reopened 16-bit TIFFs matched independent production CPU renders exactly;
ImageIO/`sips` verified named-sRGB tags, depth and dimensions. Reports, exact
settings, medians and reduced review images are in
`dist/roadmap-photographic-exports-2026-09-25/`.

The one-pass preview and three-pass export are different decode contracts.
Their whole-frame mean difference was 0.104–0.461 of an 8-bit level; individual
channel maxima were 98–250. These are not pixel-identical tiers and must not be
described using the same-source CPU/Metal 1/255 bound. Reduced paired renders
were visually inspected for framing, color and tonal agreement.

The three-frame Fuji roll test passed: look transfer, per-frame exceptions,
comparison, ordered output, three reopened TIFFs, two authoritative decodes,
one settings-only cache hit, unchanged inputs and restored settings. Temporary
full-resolution TIFFs were removed after checking.

## Remaining acceptance

Real independent Noise/HDR captures are unavailable in the 72-file local RAW
inventory; the apparent Phoenix repeat is a byte-identical copy and the nearby
Lucky scenes are different film frames. This quality check is pending by owner
request. Synthetic stack mechanics remain covered by the native suite.
Hands-on packaged-app pointer/keyboard feel and Preview/Photos/DNG-viewer judgment
remain separate from automated checks. Developer ID signing/notarization and an
independent-Mac install are last priority by owner request.

Final source verification passed 739 native tests (17 opt-in skips, zero issues),
4,608 comparator cases (4,164 GPU / 444 CPU routes), all 24 diagnostic Python
tests, strict formatting of 20 changed Swift files, and whitespace checks.
The final engine again reproduced all 254 app-applied recipe pixels and all
five preference hashes after the geometry changes.

Task logs and the pre-edit source inventory are in `dist/roadmap-2026-09-25/`.
The color study completed before the additive perspective changes; final
regression results and post-geometry recipe/preference checks are recorded in
[development status](native-macos.md#verification-summary).
