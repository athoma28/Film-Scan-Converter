# Reference Negative Calibration

**Status:** Existing offline tooling and recorded profile evidence. Further
corpus preparation and named-stock fitting are parked until the project owner
reactivates them; see the [roadmap](../improvements/MacOS-Native-Roadmap.md#parked-stock-and-capture-look-calibration).
The sample counts and fit scores below are historical measurements, not a live
inventory of the untracked corpus.

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
3. maps the XMP crop back into the decoder's active RAW rectangle, rotating
   Adobe's oriented export back into the sensor decode via `tiff:Orientation`
   so portrait scans align like landscape ones;
4. skips (rather than aborts on) any frame that fails to decode or align,
   logging the stem and reason and continuing with the remaining corpus;
5. scores current and Legacy neutral renders against the manual JPEG;
6. scores any matching shipped stock profile as a separate baseline;
7. fits monotone 11-point curves plus exposure and channel-ratio normalization;
8. grid-searches the exposure and channel-ratio anchors on held-out error for
   sets with enough frames, and on in-sample error for smaller stocks instead
   of assuming the full-set `0.5`/`0.25` defaults;
9. selects a generic color candidate with stock-balanced leave-one-stock-out
   validation, rather than allowing a large stock folder to dominate;
10. reports leave-one-frame-out error for candidates with at least three frames;
    smaller stock folders still emit explicitly unvalidated fitted curves and
    base medians for experimental alternate looks.

The July 27, 2026 corpus contains 32 triplets: 26 color and six monochrome.
The expanded generic-color candidate reached `0.120` stock-balanced
leave-one-stock-out MAE. It was not promoted: its roughly 4.4% macro-average
improvement missed the 5% threshold, and it regressed the current rendering on
both Fuji 400 Fresh and Fuji 200 Expired. The current generic profile therefore
remains the safer default.

A stock directory is not enough evidence to replace the generic default or
drive automatic stock selection. Require at least three varied frames and a
material held-out improvement (currently 5% relative) for that.

- Harman Phoenix II now has 12 varied references. Its Camera Raw LUT fit
  reaches `0.090` leave-one-frame-out MAE versus `0.159` for the current generic
  rendering, a roughly 43% reduction. That LUT still ships as the Harman
  Phoenix II stock choice under **Natural** (`harmanPhoenixIIAlternate`).
  Cyan/purple camera scans auto-select **Darkroom** with Harman Phoenix II,
  a log-density invert (independent channel stretch,
  Fujicolor Crystal Archive paper, 20% rebate inset) tuned toward a same-scene
  phone JPEG of a dusk plaza photographed at a different time of day. The
  physical profile is not a Camera Raw LUT; sampled MAE versus the ACR JPEGs
  is a collapse check (`physical ≈ 0.090` on three frames), not the color
  target.
- CineStill 800T now has two references. Refitting both moves its matching-set
  MAE from `0.116` to `0.093`; it remains labeled experimental because two
  frames cannot provide an independent held-out result.
- Fuji 400 Fresh now has 11 references. A refit moves matching-set MAE only
  from `0.123` to `0.122`, while leave-one-frame-out MAE is `0.128`. The
  existing eight-frame alternate is retained rather than churned for a
  sub-percent in-sample change.
- Fuji 200 Expired still has one reference, and its existing alternate
  (`0.0711`) already matches or slightly beats the new candidate (`0.0712`).
- Shanghai GP3 now has six references, including a portrait scan that only
  aligns after the `tiff:Orientation` fix. Its stock-specific curve reaches
  `0.126` in-sample and `0.143` leave-one-frame-out MAE versus `0.137` for the
  generic B&W curve, and `0.146` for Legacy. The GP3 curve ships as an explicit
  **Shanghai GP3** stock choice under Natural (`shanghaiGP3Alternate`) with a
  half-strength exposure anchor; the generic B&W curve remains the default.
