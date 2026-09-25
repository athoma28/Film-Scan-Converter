# Evaluating color and film presets against references

This is the operating guide for an agent continuing the Camera Raw/FSC studies.
Use it to reproduce the comparisons, diagnose a color complaint, and produce
reviewable FSC corrections. The scripts render through the production Swift CPU
engine; they do not approximate FSC with an external editor or change app defaults.

## Current compatibility

Reviewed September 25, 2026.

The current workflow uses canonical `FilmBase` inversion and public `LookRecipe`
controls throughout. Native renders capture schema-2 recipes; Python never
relabels old full-parameter documents as new recipes. Pro Image and skin fits
change public color controls and curves, retaining the required film base and
private calibration. Automatic initialization shares the app's classifier and
recommended look. The Lucky gallery uses the native Clean Invert/Foliage IDs.

Frozen preferences are a separate cohort rendered from their exact historical
settings **and historical measured medians**. Medians are deliberately absent
from serialized `FilmNegativeParams`; using freshly analyzed medians would not
reproduce the two saved Phoenix stock looks. The ledger remains unchanged.

The actual app-parser probe applies every published recipe to its required
canonical base and freshly measured source calibration, then requires both
parameter equality and exact production CPU pixels. It separately checks that
pasting retains destination geometry and private calibration. Selecting a
different film base or using a noncanonical calibration intentionally changes
that result.

The September 18 reports remain historical evidence. See the current
[verification summary](native-macos.md#verification-summary) for completed runs,
cohorts, failures, and output/Metal coverage. A preflight or parser-only pass is
not a complete photographic validation.

## Start with the existing evidence

If present, inspect `dist/camera-raw-study/skin-review.html`,
`proimage-review.html`, and `index.html` before running another fit. That directory
contains the original private study artifacts and is not in git. These paths and
the previously used localhost port are conveniences, not assumed services.

Read the relevant historical note:

- [Paired controls study](camera-raw-color-study-2026-09-18.md): initial inversion,
  sliders, curves, transfer, crop sensitivity, and control limitations.
- [Pro Image follow-up](proimage-color-followup-2026-09-18.md): channel separation,
  contrast, and the difference between numerical closeness and preferred looks.
- [Segmented skin study](skin-rgb-study-2026-09-18.md): RGB mathematics, bounded
  fits, non-skin controls, failed stock transfer, and selected recipes.

The historical corpus had 40 complete triplets across eight stocks, including six
monochrome images. Skin annotations cover 15 frames across seven color stocks.
These counts are checkpoints, not discovery limits. `doctor` reports today's inputs.
The Pro Image and skin follow-ups still contain frame-specific assumptions; see
“Adding photographs” before extending them.

## Reproduce a study

Run commands from the repository root. Requirements: macOS 14+, Swift 6,
`libraw` and `pkg-config` (Homebrew), and Python 3.11+. Reuse a suitable `.venv`.
For a new environment:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r native/diagnostics/requirements-color-study.txt
```

The requirements pin the Python versions used for the original study. LibRaw,
Swift, OS, and Python versions are recorded by the runner; changing them can
change pixels. SciPy is not required. Do not upgrade a working environment just
to inspect existing artifacts.

Place the authorized private triplets under `sample-raw/<stock>/`:
`FRAME.RAF`, `FRAME.xmp`, and the Camera Raw reference `FRAME.jpg`/`.jpeg`.
These inputs are not distributed with the repository. Discovery starts from
lowercase `*.xmp`, matches the RAF stem case-insensitively, prefers an exact JPEG
stem, then sorts `FRAME-…` / `FRAME_…` alternatives. Names containing `cnegprofile`
are excluded as targets. Inspect `inventory.json` if several JPEG edits exist;
do not assume the chosen alternative is the desired edit. Never substitute a
neighboring frame: `DSCF5672.jpg` does not complete `DSCF5671.RAF`.

```sh
# Both commands are read-only: check setup, then inspect the command sequence.
.venv/bin/python native/diagnostics/color-study.py doctor \
  --workflow skin --output dist/skin-study-next
.venv/bin/python native/diagnostics/color-study.py plan \
  --workflow skin --full --output dist/skin-study-next

# Builds and runs all stages using an isolated renderer.
# Completion also requires the current app-parser probe to pass.
.venv/bin/python native/diagnostics/color-study.py run \
  --workflow skin --full --output dist/skin-study-next
```

| Workflow | Scope | Main review page |
|---|---|---|
| `paired` | Discover/decode, register, baseline and curve fits, sliders, transfer, automatic, crop checks | `index.html` |
| `proimage` | Paired workflow plus the two Pro Image public-color studies | `proimage-review.html` |
| `skin` | Both preceding workflows plus segmentation, public-color/red/joint trials, transfer, preset publication | `skin-review.html` |

`--full` adds the existing study-specific full-resolution export cohorts; it does
not export every photograph. Without it, the run makes proxy-level claims only.
The complete skin workflow makes hundreds of production renders and multiple
gigabytes of artifacts; run stages sequentially. `plan` does not execute them.
Use one process per output directory and leave source/input files unchanged
while it runs.

The runner writes `color-study-run.json`: source and input **content SHA-256s**,
renderer hash, tool versions, options, completed stages, and active stage. The
renderer is copied into the output directory and used for every native job, so
another build cannot replace it mid-study. Source/input integrity is checked
again before completion. Each
stage has a numbered log. To continue an interrupted run, use the exact same
command with `--resume`. A changed source, selected input, pinned renderer, environment,
workflow, or `--full` setting requires a new output directory. Do not delete or
edit the manifest to bypass a mismatch.

The runner cannot adopt older populated directories without provenance. Keep
`dist/camera-raw-study` for historical comparison. Lower-level stage scripts are
available for focused experiments, but their caches do **not** enforce freshness.
Do not mix new engine results with old baselines and call it a fresh comparison.
The manifest fingerprints inputs, not every generated artifact; it is a resume
guard, not proof that manually edited output is intact. Absolute paths in the
inventory also mean moving a study between checkouts requires regeneration.

For manual builds or the standalone clipboard probe:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/fsc-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/fsc-swiftpm-cache \
swift build --disable-sandbox -c release \
  --package-path native/FilmScanEngine --product FilmScanLookbook
.venv/bin/python native/diagnostics/run-tonality-probe.py \
  --paired-recipes dist/skin-study-next
```

The probe links the release engine and actual app clipboard parser with an
in-memory pasteboard. It checks schema-2 corrections and named presets, exact
applied parameters and rendered pixels, and retention of destination framing
and private calibration. It does not touch the real clipboard or the user's
preset store. Rebuild after engine changes; the standalone probe never rebuilds.

## Measurement rules

1. **Register before measuring.** The paired tool uses SIFT/RANSAC to align the
   edited JPEG to the 900px sensor-oriented render. Require at least 20 inliers,
   at least 35% central coverage, and median residual no greater than 1.5px.
   Inspect `aligned-reference.png`, edges and subject features anyway. Log rejected
   frames in `aligned-inventory.json`; do not quietly improve averages by omitting them.
2. **Use corresponding pixels in the same display space.** FSC and reference
   decoding use the native study path. XMP is evidence about the edit, not a set
   of numerically equivalent FSC sliders. Arrays are BGR; report values as RGB.
   Do not compare a scene-linear buffer against an encoded JPEG. Slight Gaussian
   blur (sigma 1.2px) reduces grain/registration contamination; clipping, JPEG
   processing, sharpening, and different color transforms still affect scores.
3. **Keep fitting and scoring separate.** The fixed 32px tile rule
   `(x // 32 + 2 * (y // 32)) % 4 != 0` selects roughly 75% training tiles.
   The remainder is withheld. Basic-slider fitting erodes training masks before
   downsampling. Choose recipes using training scores, then report withheld
   scores. These are within-image checks; nearby tiles are not independent photos.
4. **Segment by anatomy, not by an already-correct skin hue.** Draw conservative
   visible-skin interiors on the aligned 900px reference, save polygons, erode 3px,
   and inspect `skin-overlay.png`. Include gray/green skin in the measurement.
   These are sampled regions, not exhaustive person masks. Inspect each face,
   arm and leg separately so a large region cannot hide a poor face result.
5. **Measure collateral changes.** Explicitly annotate fabric, foliage, water,
   neutrals and other important non-skin colors. The field `backgroundChange`
   means the central area outside annotated skin and its margin; it can include
   unannotated skin. It is not proof of non-skin preservation. The masks guide
   fitting and measurement; published FSC settings affect the whole photograph.

For same-pixel display RGB values normalized to [0,1], the skin report uses:

```text
RGB MAE       = 255 × mean(abs(FSC − reference)) over pixels and channels
R−G mean bias = 255 × mean((FSC_R − FSC_G) − (reference_R − reference_G))
R−G MAE       = 255 × mean(abs((FSC_R − FSC_G) − (reference_R − reference_G)))
```

Negative R−G bias indicates less red relative to green. Signed errors can cancel:
report RGB MAE, R−G MAE, brightness change and individual regions alongside it.
The paired report's `mae` is normalized [0,1]; skin errors are 0–255 levels.
Neither is Delta E, scene luminance, or proof of colorimetric accuracy. The
Pro Image Lab/chroma measurements describe appearance, not calibrated color truth.

## Fit, transfer, and preserve preferences

The paired tool tries factory looks on the declared film base, monotone RGB
curves, and public photo sliders. Pro Image trials add Cast Cleanup and Color
Separation. Skin trials vary temperature, tint, saturation, vibrance, those two
density controls, and red curves. The skin tool estimates production
finite-difference derivatives, solves bounded public-control corrections, and **renders the candidate through FSC again**.
Linearized predictions alone do not establish the resulting pixels. Joint Pro
Image trials constrain skin plus explicit non-skin patches. See the dated skin
note and code for objective weights, bounds, regularization and failed trials.

Keep three claims separate:

| Experiment | What it establishes |
|---|---|
| Per-frame target fit | Existing FSC controls can approach this edited photograph |
| Held-out-photo correction component | A new increment can transfer onto another frame's already target-fitted base |
| Complete profile on unseen photographs/rolls | Evidence for changing a reusable profile or default, if the entire fitting/selection process excluded those targets |

The existing skin stock tests are the second kind. A stock label alone does not
justify a global red boost: daylight and blue-lit Fuji examples needed opposite
directions; shared Pro Image and Lucky corrections failed some transfer tests.
Retain failed cases. A reference-conditioned preset remains selectable and named
for its frame until broader independent validation supports promotion.

[Preference checkpoints](color-preference-checkpoints.json) freeze exact settings
and PNG hashes for Fuji 400 / DSCF3115 Automatic and both saved Automatic/stock
variants of Phoenix II / DSCF3079 and DSCF3086. The user prefers these looks.
Fuji's preferred Automatic happens to select a Phoenix rendering internally;
stock identification and preferred appearance are different questions.

The runner checks available checkpoints after the dedicated `preferences` pass.
That pass uses freshly decoded source pixels and records the historical median
metadata hash beside each frozen render; it is separate from current Automatic. Pro Image
and skin reports require all five snapshots. A mismatch stops the workflow:
compare settings and decoded pixels, inspect the appearance, and explain the
change. Encoding/environment differences may affect PNG byte hashes, but do not
silently regenerate checkpoints to make an assertion pass. Checking unchanged
archived PNGs alone does not test a changed engine. Preserve the old baseline and
render the frozen settings with the new engine too.

## Files and lower-level entry points

| File / entry point | Contract |
|---|---|
| `paired-reference-study.py` | `inventory → preferences → fit → report → basic → refine → transfer → automatic → report`; optional `crop`, `full`. The first report creates `results.json` used by later fits. |
| `proimage-color-study.py` | After paired results: `fit → report`; optional `full → report`. Assumes the two named Pro Image frames and saved favorites. |
| `skin-color-study.py` | After Pro Image: `segment → jacobians → fit → red_jacobians → red_fit → red_shared → joint_proimage → joint_proimage_rgb → joint_proimage_regions → report → publish`; optional `full → publish`. |
| `inventory.json`, `aligned-inventory.json`, `results.json` | Exact inputs/metadata, exclusions, fitted recipes and scores; absolute frame directories. |
| Per-frame `metadata.json`, `scan.bgr16` | Cached native decoded scan and its dimensions; inspect the actual metadata before reading pixels. |
| Per-frame `<variant>.bgr16` | Headerless little-endian UInt16, interleaved BGR (one channel possible for monochrome). `paired.read16` loads it using metadata. Rendered variants are display output, not scene-linear RAW. |
| `target.npy`, `alignment.json`, `mask.png` | Aligned reference float32 BGR [0,1], source-to-reference homography, and central valid content mask. |
| `<variant>.json` | Plain `ProcessingParameters`, accepted in a native study job. |
| `<variant>.recipe.json`, `<variant>.corrections.json` | Native schema-2 `recipe` plus `requiredFilmBase`; the probe checks exact reproduction on that canonical base. Full parameters remain separate. |
| `skin-presets.json` | Schema-2 named public recipes with stable IDs; emitted only for accepted changes. Downloading does not install them. |
| `skin-review-results.json`, `skin-color-results.json` | Selected recipes versus all trials, train/test/region and control-patch measurements. |
| `skin-profile-revisions.json` | Changed parameter fields plus base recipe/hash; a patch is valid only for its named base. New publication writes this inside the output directory. |
| `*-full-checks.json`, `*-export.json` | Export dimensions/timing and downsampled full-render comparisons. Skin checks bind the exact selected parameters by SHA-256. |

To record a reviewed skin revision document in the repository explicitly:

```sh
.venv/bin/python native/diagnostics/skin-color-study.py publish \
  --output dist/skin-study-next \
  --revisions-output docs/development/skin-profile-revisions.json
```

Ordinary `publish` only creates local artifacts; it does not publish externally
or install presets. Do not overwrite historical research notes merely because a
new output directory exists.

For a focused candidate, create a JSON array of jobs and call
`native/FilmScanEngine/.build/release/FilmScanLookbook --paired-study=/absolute/jobs.json`.
The implementation is in
[`PairedReferenceStudy.swift`](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/FilmScanLookbook/PairedReferenceStudy.swift)
and [`ProImageColorStudy.swift`](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/FilmScanLookbook/ProImageColorStudy.swift).
Use a new candidate name; do not overwrite the baseline:

```python
# A cached 900px trial in an unchanged, already decoded study.
import json
from pathlib import Path
frame = Path("dist/skin-study-next/proimage/DSCF5800").resolve()
parameters = json.loads((frame / "color-separation.json").read_text())
# Modify the chosen public parameters here, keeping a copy of the base.
jobs = [{"directory": str(frame), "name": "candidate-01", "parameters": parameters}]
Path("dist/candidate-jobs.json").write_text(json.dumps(jobs, indent=2))
```

A job with `raw`, `parameters`, `name`, and `directory` performs a full RAW export
and emits a JPEG plus a 900px `name-check` raster for comparison. A job with `raw`
and `target` but no parameters decodes the initial comparison variants. Native
`autoClassify`, `optimize`, and `refineColor` request the corresponding production
studies. Use the generated manifests as concrete examples; don't send the clipboard
wrapper where a job expects plain parameters.

## Adding photographs or changing the engine

Use `paired` for new corpora first. Confirm correct JPEG selection, inspect
alignment, and review automatic/baseline output before choosing an optimization
family. The paired gallery now counts discovered frames and tolerates subsets.
Its crop/full cohorts still select historical frame stems; extend those selections
explicitly when validating new images.

For Pro Image/skin work, update all applicable study configuration together:

- `skin-regions.json`: frame key, named polygons in the registered 900px coordinates.
- `proimage-color-study.py`: `PATCHES`, frame filtering/starting recipes and training-only choice selection,
  expanded content region and full-export selection.
- `skin-color-study.py`: `inventory` base recipes, `PROIMAGE_CONTROLS`, candidate
  families/retention policy in `publish`, and full-export selection.
- Preference checkpoints and comparison cohorts when new user feedback establishes
  a preferred appearance. Keep the existing favorites intact.

The follow-ups deliberately fail preflight for missing required frames or new Pro
Image frames whose hard-coded patches have not been adapted. Inspect masks again
after changes to decoder geometry, registration, orientation, proxy size or crop.
Do not rescale old annotations blindly. Start a fresh study after source changes.

When changing production processing, also check the relevant Swift tests and
CPU/Metal comparator described in the [developer guide](index.md). Existing traps:
master and channel curves currently replace rather than compose; temperature/tint
are post-inversion grading; minimum saturation is not complete desaturation;
early UInt16 clipping loses information; crop-dependent analysis can change color.
These are observed behavior, not desired semantics. A migration requires explicit
compatibility decisions, appropriate tests, and fresh visual/export evidence.

## Review and handoff

Inspect the whole image plus skin and control-region crops side by side. A local
server can serve the chosen output directory if needed:

```sh
.venv/bin/python -m http.server 8891 --bind 127.0.0.1 --directory dist/skin-study-next
```

If that port is occupied, inspect the existing service or choose another port.
Use available local image tools when browser access is unavailable. Do not equate
HTML generation with browser interaction testing.

Before reporting success, include the exact cohort/exclusions, baseline and selected
recipe names, train/test errors with units, individual problem regions, collateral
changes and failed transfers. Confirm native clipboard validation and, for export
claims, full-resolution checks for the exact selected settings. Link the local
gallery and correction documents. State whether the result is a frame-specific
recipe or a validated reusable profile, and which claims remain untested. Leave
private RAWs, JPEGs, masks and generated renders out of commits.

Runner safety checks can be exercised without RAW rendering:

```sh
.venv/bin/python -m unittest discover -s native/diagnostics -p 'test_color_study.py'
```
