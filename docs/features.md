# Features

## Production Python Application

The current production application provides:

- RAW and standard image import;
- automatic threshold-based crop detection and perspective correction;
- black-and-white negative, colour negative, slide, and crop-only modes;
- film-base, white-balance, exposure, saturation, and framing controls;
- intermediate RAW, threshold, contour, histogram, and full-preview views;
- individual and batch export.

See [How to Use](how-to-use.md) for the current workflow.

## Native macOS Application

The native Swift/macOS replacement is under active development and is not yet a
production replacement. Its current implemented scope includes:

- A buildable SwiftUI app shell with drag-and-drop file import.
- Native 16-bit standard-image decoding and preview (PNG, JPEG, BMP, TIFF).
- Pixel-equivalent LibRaw RAW decoding and preview for all five representative
  Fujifilm X-T5 RAF files at both half and full resolution.
- Deterministic helper operations: rotation (90° steps), horizontal flip,
  white frame, and aspect-ratio padding.
- Threshold generation (grayscale conversion, binary thresholding, morphological
  erosion) matching Python output exactly.
- White balance coefficient adjustment matching Python float64 output exactly.
- Saturation adjustment via RGB↔HSV conversion matching Python output within
  documented ≤1 LSB tolerance.
- Exposure adjustment matching Python float32 rounding exactly.
- `shrink_box` coordinate math for crop-box adjustment.
- Float64 NPY fixture infrastructure for intermediate pipeline stages.
- Optional GPU-accelerated live camera preview with inversion, exposure, and
  saturation controls.
- macOS CI that runs all engine tests and builds the app.
- Python CI that protects the production reference implementation.

The remaining correction pipeline (histogram equalisation, crop detection,
perspective warp, dust detection/inpainting) and the full export workflow are
still under development.

See [Native macOS Development](development/native-macos.md) for the
authoritative current step, progress, limitations, and next work.
