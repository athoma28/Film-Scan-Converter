# Photographic tone controls — September 22, 2026

This implements the [tone-control audit](tone-controls-audit-2026-09-22.md) in the
native app. It is an authored photographic response, not a reproduction of
Adobe's proprietary Camera Raw processing.

**Implementation record for version 2.** The current source creates new neutral
edits at version 4 while factory looks remain pinned to version 2. See the
[separated tone-range study](tone-range-separation-2026-09-24.md) for the newer
control contract and its verification limits; the measurements below retain
their September 22 source and workload.

## Rendering and saved edits

At this implementation checkpoint, new app edits and factory looks used
`PhotoAdjustmentParameters.schemaVersion = 2`.
Older JSON, missing-version JSON, and the legacy integer initializer retain
version 1. Existing edits are not silently converted. **Update Tone Controls**
in Tone & Light explicitly upgrades a saved edit, reverses its highlight sign,
and records an undo step. Its appearance changes; numerical equivalence between
the two models is not promised. Export, clipboard, named looks, and per-file
settings carry the selected version.

Version 1 also retains the decoded `densityPaperID` compatibility setting.
The public film-base/recipe workflow still uses the neutral inversion response.
This fixes a prior loss of the paper setting on load without adding a new paper
selector. All five frozen preferred-look PNGs were freshly rendered and match
their original SHA-256 hashes; checkpoints were not updated.

## Tone contract

- Exposure applies a `2^EV` gain with a gain-dependent highlight compression;
  positive EV does not create a hard white plateau. It is not an unbounded
  scene-linear output.
- Brightness bends the midtones with fixed black/white anchors rather than adding
  a constant to RGB. Darkening does not subtract shadow detail to zero.
- Contrast changes slope around 18% linear gray and preserves both endpoints.
  Reducing it no longer lowers the white endpoint to middle gray.
- Positive Highlights and Shadows brighten their respective tonal ranges.
  Their smooth, compact bends remain monotone at either slider limit.
- Whites and Blacks independently move endpoints. These controls and explicit
  curves can deliberately clip the final output.

The main controls operate on luminance and scale the linear Rec.2020 channels
proportionally. A smooth shoulder and final chroma compression avoid hard,
independent channel clipping. Gray ramps are strictly ordered in floating point
across all individual limits and all 32 combinations of the five main control
limits. Quantized exports necessarily have repeated codes at strong settings.

Version 2 keeps inversion, tone, color adjustments, curves, and wheels floating
until the final UInt16 output. Density inversion exposes unquantized paper
reflectance. Calibrated inversion removes flat intervals using a small monotone
slope and extends over-range input; power-law inversion uses a common 18% gray
reference. Curve LUT values retain 16-bit precision with float interpolation and
endpoint extrapolation. The GPU uses a Float32 working format so adjacent LUT
codes do not collapse in half precision. Arbitrary authored curves can still
reverse tones; the monotonicity guarantee concerns the main tone controls.

## Interactive rendering

Version 2 density analysis uses the immutable sensor source, bounded to 256px,
independently of crop/rotation. CPU export, retained GPU previews, and interaction
proxies share that domain. A crop cannot remeter the image. Cropped density-print
edits can therefore stay on the GPU.

At full RAW preview resolution, slider gestures use the retained 2048px source
for both GPU rendering and CPU fallback. CPU preparation retains reusable
geometry; its retained buffer is included in memory accounting. Release renders
the exact full-size result. Detail/100% viewport requests keep their full source.

## Validation

The final complete release suite passed: **687 tests reported, zero issues,
396.198 seconds**, including the locally available RAW reference tests.
The earlier compatibility failures were corrected without changing reference
hashes or weakening pixel tolerances. Strict Swift lint and `git diff --check`
also passed for the changed implementation.

- 4,132 synthetic comparator cases: 3,796 CPU/Metal comparisons within 2/255;
  336 explicit CPU fallback cases verified. Includes legacy edits, current film
  bases, all factory looks, slider extremes, endpoint controls, combined grading,
  alternate inversions, crop, flip, and quarter turns.
- Five frozen preferred looks: exact PNG SHA-256 matches after fresh renders.
- Native app integration: cropped density-print GPU drag, legacy cropped CPU
  drag bounded to 2048px, full-resolution refinement, undoable version upgrade,
  and endpoint settings through the real correction document parser.

- 126 fresh photograph renders across six scans, including three additional
  frames beyond the audit cohort: every CPU/Metal comparison within 1/255.
  Reviewed skin, camera/clothing, foliage, road, stone, deep shadows, and bright
  background detail. These are control sweeps, not ACR fits or proof of a stock
  profile's general validity.
- Three 7752 × 5184 JPEG exports using combined controls completed. Their
  downsampled checks and a 100% skin/texture region were inspected. Full export
  took 15.7–18.6 seconds including decode/render/write while the test build was
  running; those times are not isolated performance benchmarks.

### Measured tone behavior

| Production ramp check | Audited version 1 | Version 2 |
|---|---:|---:|
| Brightness −0.5, black ramp samples | 33.18% | 0.0015% (the zero endpoint) |
| Brightness +0.5, black input output | 84.6/255 | 0/255 |
| Contrast −1, white input output | 174.2/255 | 253.9/255 |
| Contrast +1, clipped-white samples | 31.69% | 0% |
| Highlights +1, descending ramp steps | 10,766 | 0 |

After +2 EV and a quarter-output curve, input codes 160/192/224/255 now produce
53.92/58.31/61.49/63.47 rather than a shared 63.75 plateau. The original .6/.9
linear highlight counterexample now produces .823/.925 in the correct order.
At Brightness −0.5, Contrast +0.5, Exposure +1 and Contrast −1, all three original
content regions have zero black and near-white channel occupancy. This excludes
film borders/holders, not difficult image content.

### Interaction timing

Apple M4 Pro, same 40 MP source and 80% × 80% manual crop as the audit; three warm
samples with CGImage output fully consumed:

| Case | Median |
|---|---:|
| Uncropped 2048px drag | 9.27 ms (audit: 10.21 ms) |
| Cropped 2048px drag | 5.79 ms (audit cropped full-CPU drag: 2068.10 ms) |
| Full-size uncropped release | 133.29 ms (audit: 107.81 ms) |
| Full-size cropped release | 66.88 ms |

The drag improvement comes from the new bounded GPU route. Full-size refinement
has additional float processing cost; the uncropped median increased in this
small sample. These measurements exclude event dispatch, display presentation,
and ACR. They do not establish mouse-to-screen latency or ACR speed parity.

### Evidence and limits

Local, ignored artifacts:

- [Ramps, six-frame sweeps, hashes and timings](../../dist/tone-controls-fixed-final-2026-09-22/index.html)
- [Additional-frame contact sheet](../../dist/tone-controls-fixed-final-2026-09-22/heldout-contact.png)
- [Five preferred-look checks](../../dist/tone-controls-fixed-final-2026-09-22/preferences/checks.json)
- [Full-resolution checks](../../dist/tone-full-output-2026-09-22/checks.json)

The archived 900px inputs and fresh full-resolution exports use different
preview/full decode paths and analysis samples. Their central-region, lightly
blurred mean differences are 5.38/255 (Fuji), 3.40/255 (Pro Image), and 1.72/255
(Phoenix), with 99th-percentile differences 14.99/8.07/6.05. These are reported
rather than claimed as exact preview/export parity. Same-input CPU/Metal parity
is tested separately. Final aesthetics and slider feel remain subject to the
user's review; no preference checkpoint was replaced by an ACR error score.

A local Apple Silicon app bundle and ZIP were assembled in
`dist/tone-controls-app-2026-09-22/`. Dependency validation and strict ad-hoc
signature checks passed for both the bundle and extracted archive. This is a
local build, not a notarized public release.
