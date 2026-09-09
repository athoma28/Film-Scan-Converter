# Film Processing And Calibration Reference

The app already provides Natural, Darkroom, Classic, and measured-density
conversion. This page documents their boundaries and the research constraints
needed to maintain them. It is not an implementation sequence.
[Development status](development/native-macos.md) owns current validation;
[the roadmap](improvements/MacOS-Native-Roadmap.md) owns active work.

## Implemented Processing Models

| Model | Contract |
|---|---|
| Natural | Reference-derived monotone negative curves, per-frame exposure adaptation, and partial color-channel anchoring. Existing stock alternatives have recorded fit provenance and limits. |
| Classic | Exponent-based inversion using film-negative references and display rendering. Its camera conversion and native noise/detail policy do not claim full RawTherapee parity. |
| Darkroom | sRGB linearization, log-density dye unmix, sampled per-channel bounds, neutral-axis cast removal, and film/paper rendering. Profiles carry their own provenance. |
| Measured density | Capture normalization, optional flat field, measured film base, capture correction, stock response, and display rendering; shared CPU preview/export path. |

The input contract is explicit at each stage. Camera-scan `UInt16Image` values
are encoded BGR; they must be linearized where required before density or
linear-light correction. A standard JPEG or TIFF is not assumed to be an
untouched sensor measurement. Preview and final RAW export use different
demosaic-quality tiers while retaining the same adjustment semantics.

## Keep Calibration Concepts Separate

- **Film base:** measured from unexposed material for a particular scan/roll.
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
  recorded spec-sheet or tuned provenance, not Natural curve-fit outputs.

Existing profile persistence, migrations, synthetic tests, and rendering
contracts remain supported. No reference is refreshed merely to make a new
implementation pass.

## Offline Tools

[Reference negative calibration](development/reference-negative-calibration.md)
describes recursive triplet discovery, XMP geometry alignment, monotone curve
fitting, and profile-specific evidence. [Density-matrix calibration](development/density-matrix-calibration.md)
describes weighted affine fitting and frame-level validation partitions.
Neither tool installs an unreviewed candidate automatically.

The reference corpus is local and untracked. Recorded sample counts and fit
scores describe the datasets used for those fits, not the current directory's
inventory. Profile provenance is necessary to distinguish measured, tuned,
and experimental options.

## Parked Research

Further corpus preparation, named-stock fitting, characteristic-curve
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
