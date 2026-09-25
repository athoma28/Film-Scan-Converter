# Film Processing And Calibration Reference

The engine retains several inversion models and their historical calibration
data. Current Develop uses Film Base plus public-control LookRecipe presets;
its look menu no longer offers Natural/Darkroom/Classic or stock/paper choices.
Calibrate still offers scanner/capture, film-response, and measured-roll workflow
profiles. The color-negative Film Base defaults use density-print inversion with
a neutral paper response. This page records engine concepts and provenance rather
than the current inspector layout.
[Development status](development/native-macos.md) owns current validation;
[the roadmap](improvements/MacOS-Native-Roadmap.md) owns active work.

## Engine Models And Historical Names

| Model | Contract |
|---|---|
| Natural | Reference-derived monotone negative curves, per-frame exposure adaptation, and partial color-channel anchoring. Existing stock alternatives have recorded fit provenance and limits. |
| Classic | Exponent-based inversion using film-negative references and display rendering. Its camera conversion and native noise/detail policy do not claim full RawTherapee parity. |
| Density print (historically Darkroom) | sRGB linearization, log-density dye unmix, sampled per-channel bounds, and neutral-axis cast removal. New Film Base defaults use a neutral paper response; legacy edits may retain a stored paper profile with its own provenance. |
| Measured density | Capture normalization, optional flat field, measured film base, capture correction, stock response, and display rendering; shared CPU preview/export path. |

The input contract is explicit at each stage. Camera-scan `UInt16Image` values
are encoded BGR; they must be linearized where required before density or
linear-light correction. A standard JPEG or TIFF is not assumed to be an
untouched sensor measurement. Preview and final RAW export use different
demosaic-quality tiers while retaining the same adjustment semantics.

## Keep Calibration Concepts Separate

- **Film Base selector:** chooses the invert family in Develop, independently of
  a look. Color C-41 and cyan-mask use density-print inversion; B&W uses its own
  negative invert, while Slide and Original do not invert.
- **Measured film base:** sampled from unexposed material for a scan/roll in Calibrate.
- **Flat field:** captures illumination/sensor-coordinate variation for a setup.
  It must be aligned with the source geometry; per-capture flat-field processing
  is not integrated with stacking, so that combination is disabled.
- **Manual dye crossover:** a neutral-preserving linear-light operator before
  tone/curves/grading, available for color-negative paths. It is not a fitted
  density-space capture correction.
- **Capture correction:** an affine BGR density transform after film-base
  subtraction and before the stock response. The offline fitter emits a
  candidate; the app has no validated built-in correction from that fitter.
- **Natural reference looks:** fits to paired RAF/JPEG/XMP edits. These supply
  starting looks, not universal emulsion measurements or automatic stock labels.
- **Darkroom unmix and papers:** density/print model parameters with separately
  recorded spec-sheet or tuned provenance, not Natural curve-fit outputs. The
  present Film Base defaults resolve to the neutral paper response.

Existing profile persistence, migrations, synthetic tests, and rendering
contracts remain supported. No reference is refreshed merely to make a new
implementation pass.

## Offline Tools

[Reference negative calibration](development/reference-negative-calibration.md)
describes recursive triplet discovery, XMP geometry alignment, monotone curve
fitting, and profile-specific evidence. [Density-matrix calibration](development/density-matrix-calibration.md)
describes weighted affine fitting and frame-level validation partitions.
Neither tool installs an unreviewed candidate automatically.

The September 18 paired color/control investigation is active, separately from
the broader parked calibration project. Its [runbook](development/color-evaluation.md)
records current recipe/schema migration blockers and the required preference,
parser, full-resolution, and CPU/Metal checks. Historical fit scores do not
validate current factory looks.

The reference corpus is local and untracked. Recorded sample counts and fit
scores describe the datasets used for those fits, not the current directory's
inventory. Profile provenance is necessary to distinguish measured, tuned,
and experimental options.

## Parked Research

Beyond that active study, broader corpus preparation, named-stock fitting, characteristic-curve
digitization, residual 3D LUTs, halation compensation, and ML are dormant until
the owner explicitly reactivates the work. Existing code is not authorization
to collect data or fit new profiles.

A resumed experiment needs a concrete photographic defect, licensed representative
pairs, a fixed capture/decode contract, and a bounded scope. Split fit and
validation by source frame rather than adjacent pixels. Compare with the current
render and an appropriate neutral baseline; report per-stock regressions as well
as aggregate error. Small in-sample improvements do not establish generalization.

Any promoted change must preserve deterministic processing, document rounding
and clipping, pass CPU/GPU parity where applicable, and receive visual judgment
on held-out scans. Generic controls should remain useful without a named-stock
fit. The [research brief](research-brief-film-inversion.md) defines the minimum
information for proposing such an experiment.
