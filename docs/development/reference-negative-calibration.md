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
5. fits monotone 11-point curves plus exposure and channel-ratio normalization;
6. reports leave-one-frame-out error for generic and per-stock candidates.

The July 2026 13-triplet fit selected half-strength exposure normalization and
quarter-strength channel-ratio normalization for the generic color profile.
Its leave-one-frame-out mean absolute error was about `0.130`, versus `0.221`
for the previous fixed profile and `0.206` for Legacy on the ten color frames.
The Shanghai GP3 frames exposed the previous B&W profile's near-white midtone
plateau: its neutral error was about `0.407`. The replacement uses full
green-median exposure anchoring and a steeper curve; Legacy remains available
because it still has the strongest held-out result on the small three-frame B&W
set.

A stock directory is not enough evidence to ship a named built-in profile. Add
one only when it has at least three varied frames and its held-out result beats
the generic candidate on the same frames by a material margin (currently 5%
relative). The eight-frame Fuji 400 candidate reached `0.137` held out versus
`0.139` for the generic fit on those frames, only about a 2% reduction. It
therefore remains a reported candidate rather than a product preset.
