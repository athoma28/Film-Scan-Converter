# X-T5 upstream color-policy study — October 3, 2026

Retain the current X-T5 decoder policy. The upstream-color candidate worsens
full-resolution Clean Invert reference error by **16.5%** across 34 color frames,
worsens 22 of those frames, and visibly changes all five saved preferred looks.
Several full outputs become nearly black or acquire extreme casts. All 40
complete pairs were rendered and scored; no difficult candidate was omitted.

This study tests the X-T5 experiment identified by the
[upstream audit](upstream-color-audit-2026-10-03.md), following the
[color evaluation runbook](../development/color-evaluation.md). The user requested
the complete available cohort, including full-resolution output. It completed
500 renders and 90 full-resolution JPEGs. Processing defaults, installed presets,
the source decoder and the preference ledger remain unchanged.

This is the canonical results record. The separate
[reproduction record](xt5-matrix-reproduction.md) gives the required inputs,
historical source/environment and regeneration steps. Completed galleries,
exports and numeric image caches are retired; the small structured report and
source/input bundle remains in the local output root. The following observations
and validation counts describe the original run.

## Question and controlled change

Would retaining LibRaw 0.22.2's existing X-T5 camera-color state improve current
FSC photographs with their existing settings? This is a decoder-policy A/B, with
no fitting, new film calibration, or changes to shipped defaults.

The baseline is a snapshot of the current production Swift engine and native
Metal renderer. The candidate uses that same snapshot with only
`fsc_restore_legacy_raw_color` disabled by the diagnostic compile definition
`FSC_DIAGNOSTIC_UPSTREAM_XT5_MATRIX`. The geometry compatibility helper remains
active in both arms. The patch exists only in the ignored snapshot; the
application's decoder source is untouched.

The candidate retains LibRaw's `cam_xyz`, `rgb_cam`, derived `pre_mul` and
`raw_color=0`; the baseline restores the established identity color state,
`pre_mul=[1,1,1,0]` and `raw_color=1`. Upstream multipliers are approximately
`[2.1627493,0.9365458,1.4334993,0]` at unpack. Both demosaiced and later decoded
pixels change; this is not an isolated matrix multiplication after otherwise
identical demosaicing. The unpack-time multiplier difference alone does not prove
a white-balance scaling difference later in processing. White balance settings, source geometry,
demosaic implementation, `adjust_maximum_thr=0.75`, and downstream FSC processing
remain fixed.

With the unchanged `use_camera_wb=1`, LibRaw's
[scaling code](https://github.com/LibRaw/LibRaw/blob/0.22.2/src/postprocessing/postprocessing_utils_dcrdefs.cpp#L161)
replaces the unpack-time multipliers using the white samples or camera white
balance. All 40 inputs retain the same positive camera white-balance values in
both arms. In contrast, [Lab initialization](https://github.com/LibRaw/LibRaw/blob/0.22.2/src/demosaic/ahd_demosaic.cpp#L48)
uses `rgb_cam`, and FSC's
[X-Trans implementation](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/CLibRawShim/XTransDemosaicBody.inc)
uses those Lab values when selecting interpolation directions. This is a
source-supported route by which the camera matrix affects demosaicing before
final RGB conversion. Scaled mosaic values were not separately instrumented.

The metadata probe checks the known layout and matrix in all 40 RAFs before
rendering. The two arms must have identical unpacked mosaic hashes and geometry;
later decode hashes may differ. The existing full-resolution Fuji DSCF2833
decode fixture provides a separate baseline continuity check.

## Cohort and measurements

Discovery found 40 complete RAF/XMP/edited-JPEG triplets across eight stocks:
34 color and six monochrome photographs. Lucky DSCF5671 and DSCF5676 lack the
required reference triplets and are reported as input exclusions. No neighboring
photograph substitutes for either missing reference.

For every complete pair, the baseline preview initializes three recipes:
film base only (`natural`), the first recommended look (`clean`), and current
automatic initialization (`automatic`). Both arms and both decode tiers then use
those same public parameters. Ordinary renders measure fresh source medians per
arm/tier, as production does. Candidate classification or target-dependent
refitting cannot improve its score. Clean Invert is the declared primary result;
the other two recipes remain in the report.

Preview sources decode to 3876 × 2592 and render at 900 × 602. Full sources decode
and correct at 7752 × 5184, then downsample to the same scoring grid. Full JPEGs
are written for Clean Invert in both arms for every frame. Five frozen preferred
looks are a separate cohort, using their exact historical parameters and measured
medians in both arms and both tiers; each full preferred render also writes a JPEG.
Completed coverage is 500 corrected renders and 90 full-resolution JPEGs.

Edited references are registered with the maintained SIFT/RANSAC implementation.
Both arms use the same baseline transform and masks for scoring; independent
candidate registration is an additional quality check. A candidate registration
failure remains visible and does not silently remove a difficult photograph.
Masks include the central valid image, 52 individual skin regions on 15 frames,
and six explicit Pro Image fabric/foliage/tree controls. The area outside annotated
skin can contain unannotated skin and is labeled accordingly.

Errors use display RGB levels from 0–255, Gaussian blur sigma 1.2px, and equal
weight per photograph. Color and monochrome aggregates are separate. RGB MAE,
R−G error/bias, brightness differences, clipping and individual regions are
retained. A regression flag means an RGB MAE increase greater than one level or
10%; it is a review threshold, not a calibrated perceptual boundary. The fixed
75/25 spatial tile split is reported for continuity, but no fitting or selection
uses either split. These edited JPEGs are appearance references, not colorimetric
ground truth, and this is not unseen-roll profile validation.

Current public recipes are replayed through the real app text parser, with exact
parameter and CPU-pixel checks plus framing/private-calibration preservation.
Historical preference representations are explicitly excluded from that public
recipe check. Actual Metal output is compared with CPU output on a 900px source
for each render; full-source cases use a proxy from the full decode. This does
not establish full-resolution Metal equality or app interaction performance.

## Results and decision

The following are equal-photograph mean errors against the edited references;
smaller values mean closer appearance, not necessarily a better photograph.
Full-tier scores use downsampled production full-resolution corrections.

| Cohort / recipe | Tier | Baseline RGB MAE | Matrix RGB MAE | Change | Frames better / worse |
|---|---|---:|---:|---:|---:|
| 34 color / Clean Invert | Preview | 38.53 | 41.35 | +2.82 | 14 / 20 |
| 34 color / Clean Invert | Full | 37.95 | 44.21 | +6.26 | 12 / 22 |
| 34 color / film base only | Full | 38.17 | 44.17 | +6.00 | 12 / 22 |
| 34 color / fixed Automatic | Full | 40.68 | 46.96 | +6.28 | 11 / 23 |
| 6 monochrome / Clean Invert | Full | 47.02 | 46.27 | −0.75 | 3 / 3 |
| 6 monochrome / film base only | Full | 47.60 | 46.63 | −0.98 | 3 / 3 |
| 6 monochrome / fixed Automatic | Full | 38.31 | 49.24 | +10.93 | 2 / 4 |

Clean Invert flags 21/34 full color frames at the declared regression threshold;
the remaining worsening is smaller than that threshold. The unchanged spatial
splits agree: mean color error increases by 6.25 levels on training tiles and
6.27 on withheld tiles. Neither split was used to fit or choose the candidate.

| Stock | Frames | Full Clean baseline | Full Clean matrix | Change |
|---|---:|---:|---:|---:|
| CineStill 800T | 2 | 46.36 | 66.04 | +19.68 |
| Expired Fuji 200 | 1 | 54.54 | 56.92 | +2.38 |
| Fuji 400 | 11 | 35.05 | 44.45 | +9.40 |
| Gold 200 | 2 | 47.52 | 37.46 | −10.06 |
| Phoenix II | 12 | 35.56 | 39.79 | +4.23 |
| Lucky C200 | 4 | 42.34 | 49.68 | +7.34 |
| Pro Image | 2 | 33.15 | 37.02 | +3.87 |
| Shanghai GP3, monochrome | 6 | 47.02 | 46.27 | −0.75 |

The largest full Clean regressions are Fuji DSCF2892 (+45.97), CineStill DSCF3247
(+43.59), Phoenix DSCF3079 (+33.21), and Fuji DSCF2833 (+25.45). Gains include Gold
DSCF5786 (−16.89), Phoenix DSCF3084 (−15.90), Phoenix DSCF3083 (−13.68) and Fuji
DSCF3115 (−10.82). Inspect the corresponding colors and preferences before
interpreting these whole-image improvements.

Full-resolution behavior cannot be inferred from previews alone. Clean Invert's
error-change direction agrees on 38/40 frames. Phoenix DSCF3086 changes from a
12.07-level preview improvement to an 11.45-level full regression; Lucky DSCF5664
changes from −1.35 to +0.65. CineStill DSCF3247 and Phoenix DSCF3079 also become
substantially darker in the candidate's full tier. Both arms use the same public
settings throughout; each tier retains production source analysis.

Full Clean skin error, equally weighted across the 15 annotated photographs,
increases from **48.13 to 54.23**; eight worsen and seven improve. Skin R−G MAE
increases from **19.07 to 27.77**, so the issue is not described by brightness
alone. Of 52 individual skin regions, 31 worsen and 29 cross the regression
threshold. CineStill DSCF3247's face changes from 66.77 to 115.81; Phoenix
DSCF3092's front cheek from 42.57 to 74.92. Their other regions remain in the
report rather than being hidden by a pooled skin average.

Outside annotated skin, the 15-frame mean increases from 41.34 to 45.94; ten
frames worsen. Five of six explicit Pro Image controls worsen. The equally
weighted control mean rises from 27.71 to 31.81; DSCF5800 greenery increases by
8.55 levels and DSCF5809 shirt by 8.27. DSCF5800 shorts improve by 2.02. These
small cohorts and spatial regions are not independent roll-level validation.

All five baseline preview PNGs exactly match the unchanged preference ledger.
All five matrix replays visibly change, at both tiers:

| Saved preference | Preview change from baseline | Full change from baseline |
|---|---:|---:|
| Fuji DSCF3115 / Automatic | 13.90 | 14.52 |
| Phoenix DSCF3079 / Automatic | 18.44 | 27.73 |
| Phoenix DSCF3079 / stock | 15.83 | 15.85 |
| Phoenix DSCF3086 / Automatic | 56.86 | 51.88 |
| Phoenix DSCF3086 / stock | 14.70 | 14.68 |

These preference values are blurred RGB differences **between the two arms over
the entire 900px raster**, including borders; they are not errors against Camera
Raw. The historical settings and medians are identical between arms. Both stock
looks acquire broad yellow/ochre changes, and the saved Automatic looks darken
or shift color. None is replaced, refitted or rebaselined.

The experiment rejects enabling this upstream color policy as a transparent
upgrade for existing FSC edits. It does not rule out a separately versioned
pipeline that changes the camera-space/inversion/working-space boundary. Such a
pipeline would be a new experiment, with its own calibration, preference and
unseen-photograph acceptance. No such redesign or default migration was made.

## Photographic inspection

Visual review includes all 40 full Clean pairs in five overview sheets, 48
unscaled 512px crop pairs from 23 full JPEG frame pairs, and all five full
preferred looks with five additional 1:1 crop pairs. Full JPEG crops were read
after decompression and hash/dimension checks. This is representative native
pixel inspection plus complete cohort overviews, not inspection of every pixel
in all 90 exports. Exact frames and observations are recorded in
`supplemental/visual-review-completion.json`.

The preview mask review covers all 15 annotated photographs, 52 individual skin
regions and six Pro Image control patches. No visibly misplaced annotation was
rejected. Candidate Fuji DSCF3115 has an independent homography discrepancy near
the frame edges, but the cheek/neck interiors remain correctly placed. Phoenix
DSCF3092 becomes too dark to confirm candidate anatomy visually; the original
reference/baseline masks and the source geometry checks remain available.

The strongest failures are not small reference-score differences. Fuji DSCF2892
changes skin and clothing to near-black/deep blue, with intense green remnants
in foliage. The same effect is present in 1:1 pixels of its full-resolution JPEG.
Phoenix DSCF3092 and Lucky DSCF5705 also lose much of their visible scene into
darkness. Other photographs show yellow-green skin, red/orange skin, purple-blue
fabric, or blue/orange crossover. Full-size Fuji DSCF2851 sky/bridge crops show
much stronger colored grain. These observations concern the produced images;
they do not establish which individual upstream stage causes every defect.

Numerical improvements are retained. Gold DSCF5786's water becomes darker/bluer
and closer to the edited reference. Phoenix DSCF3083 closes a brightness gap.
However, Phoenix DSCF3086's Clean Invert preview improves RGB MAE by 12.07 levels
while its chroma residual worsens from 13.04 to 18.50 and the sky becomes intensely
blue. Fuji DSCF3115 also scores better overall while its skin becomes yellow-green.
Brightness changes can dominate a whole-image score without improving preferred
color. The saved Automatic preference for Phoenix DSCF3086 is a different recipe;
that matrix replay becomes largely black/deep blue.

Clipping is measured at exact UInt16 endpoints, with source and corrected output
kept separate. In the registered central **preview decoded-source proxy**, Fuji
DSCF2833 gains 0.285% blue-channel upper endpoints and DSCF2851 gains 0.946%, versus
zero in their baselines. DSCF2892 gains 0.268% green-channel zero endpoints. These
are not sensor saturation measurements or full-resolution clipping fractions.
Native full-source/full-correction endpoint counts are recorded separately and
include film borders and holders. They should not be interpreted as subject-only
clipping or as a complete causal explanation of the color failures.

## Validation, failures and limits

All 172 native jobs finalized successfully. The two isolated release builds and
standalone Swift probes compiled; the C++ metadata probe compiled with
`-Wall -Wextra -Werror`. Source/input/renderer provenance and completed output
hashes were checked by the runner before scoring.

- **480 public-recipe app-parser checks pass**, with exact parameters and CPU
  pixels plus destination framing/private-calibration retention. The 20
  historical preference renders are explicitly excluded from public-recipe
  serialization; their exact historical state is tested separately.
- **500 actual GPU comparisons pass**, with maximum RGB error 1/255, no CPU
  fallbacks and no GPU failures. These are 900px comparisons, including proxies
  from full decodes; they do not prove full-resolution Metal parity.
- **90/90 JPEGs fully decompress** using independent Pillow `Image.load`, all at
  7752 × 5184, with dimensions and SHA-256s matching native metadata and completion
  records. This supplements the native ImageIO check, whose image creation can
  be lazy; the metadata wording alone was not taken as proof of decompression.
- **86/86 A/B decode pairs** retain identical RAW files, source/mosaic geometry
  and unpacked mosaic hashes. All later stage hashes differ between arms, starting
  at demosaicing. All 86 cross-tier mosaic checks and 12 same-arm ordinary/preference
  repeated-decode checks pass. Baseline full Fuji DSCF2833 matches all five stage
  hashes in the unchanged committed RAW fixture.

All 40 baseline registrations pass at both tiers. Independent matrix registration
passes 36/40 previews and 33/40 full outputs. Full candidate failures are Fuji
DSCF2892; Phoenix DSCF3079/3085/3086/3092; and Lucky DSCF5702/5705, each with
insufficient feature matches. They remain in scoring on the shared baseline
transform and verified source grid: **zero scoring exclusions**.

The primary scorer retains seven candidate registration review gates: four
failed preview fits, plus outer-grid displacement flags for Fuji DSCF2873/3115
and Phoenix DSCF3077. Independently registering baseline full versus preview
flags Fuji DSCF3115 (median 0.545px, maximum 4.256px); the other 39 have maximum
displacements at most 2.017px. Inspection found matching central subjects with
fit disagreement toward sparse backgrounds/borders. The numerical gates are
retained as registration sensitivity, not silently declared passes.

A supplemental sensitivity check uses the independently fitted full-baseline
references with the same source-coordinate masks. The 34-color-frame mean
matrix effect changes from +6.25849 to +6.25953 levels; no frame changes its
improvement/regression direction or regression flag. The largest per-frame
effect change is 0.05534 levels. Fuji DSCF3115 skin changes from −2.06340 to
−2.01536, with both cheeks and neck retaining their directions. This check
bounds the observed registration concern; it does not replace the declared
primary scoring or select more favorable results.

Consequently `analysis/scores.json` reports `failed` and scoring exits 1, despite
scoring all 40 frames and all five preferences. The runner's conservative
exception handler then marks `study.json` as `interrupted`. This is a recorded
candidate-quality failure after complete rendering, not an unfinished render
cohort. The unmodified, pre-score `render-complete` manifest is preserved as
`supplemental/render-completion-manifest.json`; the independent final validation
reports complete coverage and zero integrity/parser/GPU/export failures.

## Reproduction and provenance

The compact local bundle is `dist/xt5-matrix-study-2026-10-03/`; it contains
structured results, settings, validation records, hashes and the source/input
snapshot. Private originals remain in ignored `sample-raw/`. Neither is
distributed with the repository. The [reproduction record](xt5-matrix-reproduction.md)
explains how to rebuild temporary outputs on the current engine or reconstruct
the recorded historical source in an isolated directory. The compact original
bundle cannot resume rendering or be rescored after its pixel artifacts are removed.

Local HEAD is `2b4da0930df3ccebc08c1e3197a8ec242df448ac` plus the pre-existing
working tree. The runner copies current working sources, rather than rebuilding
HEAD. Environment: macOS 15.7.9 arm64, Swift 6.1.2, LibRaw 0.22.2, Python 3.12.7,
NumPy 2.2.1, OpenCV 4.10.0 and Pillow 11.1.0. This is not a timed performance
benchmark; supplemental image analysis can run concurrently with rendering.

`study.json` records source/input/environment and pinned-renderer hashes;
`snapshot-color-policy.patch` identifies the only experimental source change;
`matrix-state.json` records all 40 camera-state checks. Per-frame `metadata.json`,
job logs, and `completion/` hashes bind settings, decode stages, CPU output,
parser/Metal results and full exports. The current application source and the
preference ledger must remain unchanged throughout the run.

Supplemental records under the same output retain the reports from independent
Pillow JPEG decompression, full-registration comparisons, inspected mask/control
overlays, frozen-preference comparisons and 1:1 full-JPEG crops. The
reproduction-input bundle retains supporting diagnostic/annotation/ledger
sources and historical median metadata in their original repository-relative
layout, with hashes.

The former `analysis/index.html`, full-output overview, full-pixel crop and
preferred-look galleries are retired. Start with `analysis/scores.json.gz`,
`supplemental/final-summary.json` and `supplemental/visual-review-completion.json`.
Large report JSON is losslessly compressed; restore it using the
[local-data commands](../development/building.md#local-generated-data) when a
reader requires plain JSON.
`supplemental/export-validation/report.json` and
`supplemental/full-registration/scoring-sensitivity.json` record the independent
export/source checks and registration sensitivity.

At the time of the original study, documentation validation checked 62 public Markdown pages and 566 links with
zero errors; `git diff --check` passed. The generated main gallery had 1,171
local asset/link references and had no missing files before retirement. New diagnostic/report files
also passed a trailing-whitespace check. MkDocs was not available in the shell
or project virtual environment, so the public documentation site was not rebuilt.
