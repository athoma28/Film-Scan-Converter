# Upstream color audit — October 3, 2026

The upstream review found useful processing experiments, but no data refresh
that establishes better color for Film Scan Converter. Sixteen of seventeen
matching NegPy negative matrices are already identical; the remaining one is
FSC's intentionally tuned Phoenix response. The two named RA4 paper models also
match. LibRaw is already at the latest stable release reviewed, 0.22.2.

The most substantial color experiment is the X-T5 input transform: FSC disables
an existing upstream camera matrix to preserve established output. The most
interesting recent NegPy feature is roll/scene cast estimation. Neither has
been photographically validated here. This audit changes no processing code,
presets, decoder settings, or preference checkpoints.

Follow-up: the user subsequently requested the
[full X-T5 matrix experiment](xt5-matrix-study-2026-10-03.md). It completed 500
renders and 90 full-resolution JPEGs across all 40 complete pairs, rejected the
upstream color policy as a transparent default change, and retained existing
preferred looks. The audit below remains the source-review record preceding
that photographic test.

## Scope and source snapshots

The question was whether upstream projects supplying FSC's data and processing
can improve color quality. This is a source/data audit, not a rendering study or
throughput benchmark. It follows the [color evaluation runbook](../development/color-evaluation.md)
and retains the [existing research boundaries](index.md).

Local HEAD was `2b4da0930df3ccebc08c1e3197a8ec242df448ac`, with extensive existing
uncommitted native and documentation work. The review used those working files,
not just HEAD. Relevant source hashes and the initial status are retained in
ignored `dist/upstream-color-audit-2026-10-03/source-audit.json` and
`working-tree-at-audit.txt`. Unrelated changes were preserved.

| Upstream | Snapshot reviewed | Relevant role |
|---|---|---|
| NegPy | [6317387bfa90](https://github.com/marcinz606/NegPy/commit/6317387bfa90bb4d44bb05d82da2098b0fea58df), October 3 | Density unmix, cast removal, film estimates and paper response |
| RawTherapee | [94c3096e706d](https://github.com/RawTherapee/RawTherapee/commit/94c3096e706d89a2325415d56af188ca0228ce34), September 27; latest release reviewed [5.13](https://github.com/RawTherapee/RawTherapee/releases/tag/5.13) | RCD, film-negative processing concepts and camera data |
| LibRaw | Installed/latest stable reviewed [0.22.2](https://github.com/LibRaw/LibRaw/releases/tag/0.22.2); master [4f0144031c4a](https://github.com/LibRaw/LibRaw/commit/4f0144031c4adfadf7e053937826c49ed80cfa89), October 2 | RAW decode, X-Trans and camera matrix |

Public source downloads are pinned inside the ignored audit folder. They were
inspected as data, not installed or executed as an upstream application.
The other libraries in the [third-party notices](https://github.com/athoma28/Film-Scan-Converter/blob/main/THIRD_PARTY_NOTICES.md)
are not sources of these film/paper tables; their full release histories were
outside this focused audit.

## Exact data comparison

The local diagnostic `dist/upstream-color-audit-2026-10-03/compare-negpy-data.py`
extracts the Swift definitions and pinned upstream TOML/Python definitions
without importing the upstream application. Its report is
`negpy-data-comparison.json`. Re-run with the existing downloaded inputs:

```sh
python3 dist/upstream-color-audit-2026-10-03/compare-negpy-data.py
```

| Comparison | Result | Decision |
|---|---|---|
| 16 named negative matrices plus Generic C41 | 16/17 exact; 147/153 coefficients equal | No general matrix refresh to import |
| Phoenix II | Six off-diagonal coefficients differ; largest absolute difference 0.036, output G/input R | Preserve FSC's tuned response; upstream is an approximate Gold-200-valued matrix, not an independently validated Phoenix correction |
| Endura and Crystal Archive | Both match across all 11 compared fields per paper, including dye matrices, gamma and tint arrays | No update benefit |
| Neutral paper defaults | 3/11 fields differ: upstream/FSC Dmin 0.06/0, toe sharpness 6/4, midtone gamma 0.05/0.15 | Different tone choices, not demonstrated better color |
| Unmatched profiles | FSC-only Lucky response and Soft Portrait; upstream-only four B&W papers | No missing upstream color-stock matrix |

Sources: pinned [crosstalk data and provenance](https://github.com/marcinz606/NegPy/tree/6317387bfa90bb4d44bb05d82da2098b0fea58df/crosstalk),
[paper profiles](https://github.com/marcinz606/NegPy/blob/6317387bfa90bb4d44bb05d82da2098b0fea58df/negpy/features/exposure/papers.py),
[inherited paper defaults](https://github.com/marcinz606/NegPy/blob/6317387bfa90bb4d44bb05d82da2098b0fea58df/negpy/features/exposure/models.py),
local [negative catalog](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/FilmScanEngine/NegativeDensityProfile.swift)
and [paper catalog](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/FilmScanEngine/DensityPaperProfile.swift).
These are raw parameter comparisons, not rendered equivalence between apps.
Upstream's neutral Dmin is enabled only by its paper-base-density control
(`paper_dmin`, off by default); importing the number alone would not reproduce
that application.

NegPy now explicitly describes all bundled stock matrices as approximate
datasheet estimates. Its [provenance guidance](https://github.com/marcinz606/NegPy/blob/6317387bfa90bb4d44bb05d82da2098b0fea58df/crosstalk/README.md)
explains that the light spectrum and sensor response also determine channel
mixing. These estimates therefore do not constitute measured calibration for
this camera and backlight. Both applications apply strength and row normalization,
but their input domains differ: NegPy normally uses linear sensor channels;
FSC linearizes its established encoded decode before taking log density.

Current ordinary C-41 initialization uses Generic C41, followed by Clean Invert's
Color Separation 0.45 and Cast Cleanup 0.5. Cyan-mask initialization uses FSC's
tuned Phoenix response. Current photographic processing resolves neutral paper;
named RA4 papers remain relevant to legacy settings. Most catalog stock entries
do not select the ordinary new-import defaults. See
[Film Base](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/FilmScanEngine/FilmBase.swift),
[LookRecipe](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/FilmScanEngine/LookRecipe.swift)
and [paper resolution](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/FilmScanEngine/DensityPrintProcessing.swift).

## Experiments worth prioritizing

### 1. Establish the camera-color boundary

RawTherapee's current [X-T5/X-H2 camera table](https://github.com/RawTherapee/RawTherapee/blob/94c3096e706d89a2325415d56af188ca0228ce34/rtengine/camconst.json)
and [LibRaw's matrix](https://github.com/LibRaw/LibRaw/blob/0.22.2/src/tables/colordata.cpp)
agree: `11809,-5358,-1141,-4248,12164,2343,-514,1097,5848`.
FSC's [compatibility helper](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/CLibRawShim/RawDecodeCompatibility.h)
deliberately disables this exact matrix for the verified X-T5 RAF layout,
restoring older identity camera conversion. The resulting image is labeled sRGB
and later interpreted through that working-space contract.

This is the largest plausible color-accuracy opportunity found, but that ranking
is an engineering inference. A camera matrix intended for ordinary photography
is not automatically the right pre-inversion transform for illuminated negatives.
Compare the preserved camera-channel pipeline with an explicitly versioned matrix
candidate; retain source geometry independently. Also consider inversion before
versus after working-space conversion. RawTherapee's
[input-space/backlight/reference design](https://github.com/RawTherapee/RawTherapee/commit/e635030650ed54b0c2232e8d5b986db2988809f7)
provides a useful model. Existing FSC edits lack a decoder version, so a silent
matrix switch would invalidate their rendering. The
[RAW compatibility record](../development/raw-decode-compatibility.md) documents
that distinction between continuity and color calibration.

### 2. Compare roll/scene cast estimation

NegPy's September 22–23 changes pool whole-frame bounds and neutral-axis
measurements, exclude color-balance outliers, and retain part of each frame's
lighting difference. See [roll/scene cast removal](https://github.com/marcinz606/NegPy/commit/6ce27a9975d8)
and its pinned [normalization implementation](https://github.com/marcinz606/NegPy/blob/6317387bfa90bb4d44bb05d82da2098b0fea58df/negpy/features/exposure/normalization.py).
This is a concrete candidate for reducing frame-to-frame color variation.
FSC already has same-pixel highlight gating and a quadratic neutral-axis solve;
the incremental idea is pooling trustworthy measurements across related frames.
Do not copy upstream's changed cast-strength default along with the algorithm.

Evaluate scene groups separately, with frame/lighting exclusions preserved.
A shared correction must not erase intentional blue-hour light or propagate
one scene's cast to another. Reusing target-fitted per-frame recipes would not
validate an independently reusable roll correction.

### 3. Diagnose decode scaling and clipping

NegPy pins RAW scaling with `adjust_maximum_thr=0.0`, as described in its
[pipeline contract](https://github.com/marcinz606/NegPy/blob/6317387bfa90bb4d44bb05d82da2098b0fea58df/docs/PIPELINE.md).
FSC's [camera-scan decode](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/CLibRawShim/RawTherapeePipeline.cpp)
sets 0.75 and produces bounded, gamma-encoded UInt16 pixels before inversion.
First measure whether the scaling threshold triggers on this corpus and whether
any source channels clip. A common scalar may cancel in log normalization;
changing the option is not inherently a color improvement.

FSC already retains unbounded photographic inversion values and compresses
display gamut in [PhotographicTone](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/FilmScanEngine/PhotographicTone.swift).
The unresolved boundary is earlier, at RAW decoding. RawTherapee's current
[film-negative inversion](https://github.com/RawTherapee/RawTherapee/blob/94c3096e706d89a2325415d56af188ca0228ce34/rtengine/filmnegativeproc.cc)
itself clips channels, so copying that path wholesale is not an unclipped upgrade.

### Lower-priority changes

NegPy's gamut-aware Lab chroma and skin protection are alternative control
designs worth comparing only against a specific visible failure; FSC already has
protected color and soft gamut compression. Upstream also uses block-median
analysis; FSC analyzes a fixed 256px source, so the comparison must account for
the existing resize rather than assuming full-resolution isolated sampling.
Sources: [NegPy Lab controls](https://github.com/marcinz606/NegPy/blob/6317387bfa90bb4d44bb05d82da2098b0fea58df/negpy/features/lab/logic.py),
[FSC photographic processing](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/FilmScanEngine/PhotographicProcessing.swift).

No new X-T5 matrix was found in the reviewed LibRaw master changes. Its
X-Trans source blob matches 0.22.2 (`ca98dc398a57adcd5e1cad0aaad1d7bb14f1b181`).
RawTherapee RCD updates concern the Bayer path, not this X-Trans corpus.
A dependency refresh is therefore low priority for the color question.

## Existing evidence and validation boundary

Fresh read-only preflight passed:

```sh
.venv/bin/python native/diagnostics/color-study.py doctor \
  --workflow skin --output dist/upstream-color-check-2026-10-03
```

It found 40 complete triplets and excluded incomplete Lucky DSCF5671/DSCF5676.
Environment: macOS 15.7.9 arm64, Swift 6.1.2, Python 3.12.7, NumPy 2.2.1,
OpenCV 4.10.0, Pillow 11.1.0, LibRaw 0.22.2. Historical median files needed to
replay the five preferred looks exist.

The completed [September 25 study](../development/roadmap-follow-through-2026-09-25.md#reproducible-color-workflow)
remains historical evidence. Its manifest records 29 stages, 254 exact
app-parser/pixel checks, 13 presets, five preferences and 11 full JPEG exports.
Twenty-nine of its 127 recorded source files differ in today's tree; those
results do not validate today's engine or these upstream candidates.

That study also cautions against unconditional shared corrections. Fuji DSCF2555
skin RGB MAE worsened from 6.87 to 17.27 for a transferred public-color increment;
the transferred red increment gave 12.12. Pro Image DSCF5800's red transfer
worsened 3.19 to 4.66, and Lucky DSCF5664 worsened 3.79 to 5.87. Units are 8-bit
display RGB levels, not Delta E. The ignored completed run's
`skin-review-results.json` retains the individual and collateral results.

For the next experiment, freeze one candidate and current production renderer
in a fresh output. First compare fixed recipes on Fuji daylight/blue-light,
Pro Image DSCF5800/5809 with their non-skin controls, difficult Phoenix and Lucky
frames, and all five preferred snapshots. Reinspect registration after any
decode change. Report clipping, whole-image and individual skin/control-region
metrics, failures and visual preferences. Broaden to all 40 pairs before any
default decision; use separate photographs/rolls for reusable-profile claims.
Promising candidates then require real app-parser checks, exact full-resolution
exports and separate CPU/Metal evidence under the maintained runbook.

No new candidate rendering, fitting, export, parser or Metal validation was run
in this audit. The result supports these experiments and retaining current
defaults; it does not establish a measured color improvement.

The exact-data comparison script was rerun successfully. Documentation
validation (`python3 tools/check-docs.py`) checked 61 public Markdown pages and
555 links with zero errors; `git diff --check` passed. No native test run was
needed for these documentation-only changes.
