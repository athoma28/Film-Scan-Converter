# Density-Matrix Calibration

> **Parked research infrastructure.** Keep this implementation and
> its tests documented, but do not spend active roadmap time preparing a
> corpus, fitting named stocks, generating LUTs, or extending this into an ML
> experiment until the project owner explicitly asks to resume. The current
> priority is the fast, flexible photographer workflow in the
> [native roadmap](../improvements/MacOS-Native-Roadmap.md).

Film Scan Converter includes an offline fitter for the capture correction used
by the measured-density pipeline. It fits an affine BGR transform after
film-base subtraction and before the stock's per-channel density response:

```text
corrected_density = matrix * measured_density + offset
log_exposure = stock_slope * corrected_density + stock_offset
```

This fitter does not supply a validated built-in capture correction matrix;
that requires measured reference pairs and held-out validation. The current source includes separate Natural reference curves and Darkroom stock dye-unmix matrices.
Those catalogs have their own provenance and are not outputs of this affine
capture-profile fitter.
The [research registry](../research/index.md) separates this parked track from
the active [paired color/control workflow](color-evaluation.md), whose public
recipe fits do not supply a measured-density capture matrix.

## Input contract

The JSON input contains one capture profile, the stock profile used to convert
corrected density to target log exposure, and weighted patch or pixel samples.
Each sample supplies:

- `sourceFrameID`: the reference-pair frame that produced the sample;
- `measuredDensity`: base-subtracted BGR density from the negative scan;
- `targetLogExposure`: aligned target BGR expressed in the stock profile's log
  exposure domain;
- `weight`: a positive confidence/importance weight;
- `partition`: either `fit` or `validation`.

All patches from one frame must use the same `sourceFrameID` and partition. The
fitter rejects a frame that appears in both partitions, preventing neighboring
pixels from one image from leaking into its held-out score. Reference-image
alignment, patch extraction, and conversion of a target positive into log
exposure remain upstream dataset-preparation work.

## Fit and gate

The fitter solves three weighted regularized least-squares systems with an
identity-matrix/zero-offset prior. It reports fit RMSE, held-out RMSE, the
held-out identity-baseline RMSE, relative improvement, and a pass/fail gate.
The gate passes only when the fitted transform beats identity by the configured
minimum relative improvement. The document's default `minimumValidationImprovement`
is `0.01` (1% relative RMSE); this is separate from the historical 5% reference-curve
review criterion. A pass is necessary evidence, not sufficient
evidence for shipping: real candidates still need representative stocks,
capture setups, neutral/hue diagnostics, and visual review.

Choose regularization, weights and acceptance limits using fitting/selection
data. If the validation set influences those choices, it becomes selection data;
keep a separate frame/roll cohort outside that process for a final promotion claim.
Report metrics in the declared log-exposure domain, not as display-RGB MAE or
Delta E. Preserve failed reports as well as passing ones.

Run the committed synthetic smoke example:

```sh
swift run --package-path native/FilmScanEngine \
  FilmScanProfileCalibrator \
  native/FilmScanEngine/Examples/density-matrix-calibration.synthetic.json \
  /tmp/film-scan-density-calibration-report.json
```

The output contains a `candidateCaptureProfile` carrying the fitted density
matrix and the complete report. The command never installs that candidate. It
exits with status 2 after writing the report when the held-out gate fails.
The example is synthetic and must never be treated as product calibration data.

## Provenance and handoff

The schema-1 input and output definitions live in
`native/FilmScanEngine/Sources/FilmScanEngine/DensityMatrixCalibration.swift`;
the command wrapper is
`native/FilmScanEngine/Sources/FilmScanProfileCalibrator/main.swift`. Tests cover
synthetic recovery, weighting, leakage rejection and gate behavior. Those
contracts do not establish real-capture quality.

For an authorized resumed experiment, keep the exact sample-extraction and
alignment procedure, input content hashes, stock/capture profile values, source
state, tool versions, command, output and visual review together. The fitter's
JSON report does not independently record all of that provenance. Follow the
[experiment requirements](../research-brief-film-inversion.md) and
[research handoff procedure](../research/index.md#record-and-hand-off-the-decision).
