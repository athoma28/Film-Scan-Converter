# Density-Matrix Calibration

> **Parked research infrastructure (2026-07-15).** Keep this implementation and
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

This is calibration infrastructure, not a library of calibrated film stocks.
No named stock or capture matrix is built in until measured reference pairs
pass held-out validation.

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
minimum relative improvement. A pass is necessary evidence, not sufficient
evidence for shipping: real candidates still need representative stocks,
capture setups, neutral/hue diagnostics, and visual review.

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
