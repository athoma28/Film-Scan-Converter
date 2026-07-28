# Reference Negative Calibration

`sample-raw/` is an untracked, recursively organized development corpus. Each
film-stock directory may contain paired Camera Raw reference triplets:

- `FRAME.RAF` — the scan decoded through the app-facing camera-scan profile;
- `FRAME.xmp` — Camera Raw settings and normalized crop geometry;
- `FRAME.jpg` or `FRAME.jpeg` — the manually inverted reference output.

The calibrator also accepts `FRAME-adobe.jpg` and suffix variants such as
`FRAME_1.jpg`. A JPEG whose name contains `cnegprofile` is considered an FSC
output and is never used as a Camera Raw target. Recursive discovery sorts by
root-relative path, and basename-based legacy fixtures fail on ambiguity rather
than selecting a frame from the wrong stock.

Run the release calibrator from the repository root:

```sh
swift build -c release \
  --package-path native/FilmScanEngine \
  --product FilmScanReferenceCalibrator

native/FilmScanEngine/.build/release/FilmScanReferenceCalibrator \
  sample-raw /tmp/film-scan-reference-calibration.json --stride=16
```

The tool:

1. discovers color and monochrome triplets recursively;
2. decodes each RAF through `rawTherapeeCameraScan`, never its embedded preview;
3. maps the XMP crop back into the decoder's active RAW rectangle;
4. scores current and Legacy neutral renders against the manual JPEG;
5. scores any matching shipped stock profile as a separate baseline;
6. fits monotone 11-point curves plus exposure and channel-ratio normalization;
7. selects a generic color candidate with stock-balanced leave-one-stock-out
   validation, rather than allowing a large stock folder to dominate;
8. reports leave-one-frame-out error for candidates with at least three frames;
   smaller stock folders still emit explicitly unvalidated fitted curves and
   base medians for experimental alternate looks.

The July 27, 2026 corpus contains 31 triplets: 26 color and five monochrome.
The expanded generic-color candidate reached `0.120` stock-balanced
leave-one-stock-out MAE. It was not promoted: its roughly 4.4% macro-average
improvement missed the 5% threshold, and it regressed the current rendering on
both Fuji 400 Fresh and Fuji 200 Expired. The current generic profile therefore
remains the safer default.

A stock directory is not enough evidence to replace the generic default or
drive automatic stock selection. Require at least three varied frames and a
material held-out improvement (currently 5% relative) for that.

- Harman Phoenix II now has 12 varied references. Its stock fit reaches `0.090`
  leave-one-frame-out MAE versus `0.159` for the current generic rendering, a
  roughly 43% reduction. It ships as an explicit alternate, without automatic
  stock detection.
- CineStill 800T now has two references. Refitting both moves its matching-set
  MAE from `0.116` to `0.093`; it remains labeled experimental because two
  frames cannot provide an independent held-out result.
- Fuji 400 Fresh now has 11 references. A refit moves matching-set MAE only
  from `0.123` to `0.122`, while leave-one-frame-out MAE is `0.128`. The
  existing eight-frame alternate is retained rather than churned for a
  sub-percent in-sample change.
- Fuji 200 Expired still has one reference, and its existing alternate
  (`0.0711`) already matches or slightly beats the new candidate (`0.0712`).
- Shanghai GP3 now has five references. The proposed B&W refit has `0.157`
  leave-one-frame-out MAE, worse than the current calibrated curve's `0.140`
  fixed-profile score, so the shipped B&W profile remains unchanged.
