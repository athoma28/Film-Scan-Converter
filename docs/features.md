# Features

## Native Swift/macOS Application

The native application is the primary product and the only target for new
features. Its implemented scope includes:

- A buildable SwiftUI application with drag-and-drop file import.
- Native 16-bit standard-image decoding and preview (PNG, JPEG, BMP, TIFF).
- Pixel-equivalent LibRaw RAW decoding and preview for all five representative
  Fujifilm X-T5 RAF files at both half and full resolution.
- Deterministic helper operations: rotation (90° steps), horizontal flip,
  white frame, and aspect-ratio padding.
- Threshold generation (grayscale conversion, binary thresholding, morphological
  erosion) matching Python output exactly.
- White balance coefficient adjustment matching Python float64 output exactly.
- Saturation adjustment via RGB↔HSV conversion matching Python output within
  documented ≤1 LSB tolerance, including Python-equivalent clipping of
  white-balanced highlights before HSV conversion.
- Exposure adjustment matching Python float32 rounding exactly.
- Histogram equalisation with exact float64 pixel equality for B&W negative,
  colour negative, and slide with base detect.
- `shrink_box` coordinate math for crop-box adjustment.
- Float64 NPY fixture infrastructure for intermediate pipeline stages.
- RawTherapee-compatible film negative power-law inversion with neutral
  middle-gray auto-calibration via 20%-border-cut channel medians. Per-channel
  exponent model:
  `output = multiplier × pixel^-(greenExp × ratio)`. Color Negative preset
  (RedRatio=1.36, GreenExp=1.5, BlueRatio=0.86) and Black & White preset (all
  ratios=1.0) matching RawTherapee's `Film Negative.pp3` and `Film Negative -
  Black and White.pp3`. Full CPU (Double), GPU-equivalent (Float), and Metal
  CIKernel processing parity. SwiftUI controls with preset picker and per-channel
  ratio/exponent sliders.
- Automatic startup classification for new files: low-chroma scans start as
  B&W negative, orange-mask scans start as color negative, and other
  positive-looking scans start as slide. Existing per-file settings are not
  overwritten.
- Overall RGB tone curve with piecewise-linear interpolation (65536-entry 16-bit
  CPU LUTs, 256×256 8-bit GPU LUT texture). Per-channel red, green, and blue
  curves fall back to the overall curve.
- Highlight, midtone, and shadow color wheels backed by smoothstep tonal masks
  with luminance preservation. Draggable SwiftUI color wheel controls with
  double-click reset.
- Optional GPU-accelerated live camera preview with inversion, exposure, and
  saturation controls.
- A still-image correction workflow with live slider bindings, a reusable 16-bit
  Core Image/Metal preview renderer, bounded latest-value-wins scheduling, and a
  two-session decoded-preview cache with one-file lookahead predecode for the
  next uncached import.
- Render instrumentation with `os_signpost` profiling markers and published
  snapshot/display/drop counters.
- TIFF (16-bit, optional LZW compression), JPEG (8-bit, configurable quality),
  PNG (16-bit lossless), and DNG (processed 16-bit RGB in a valid TIFF container)
  export with individual and batch-all workflows, background processing,
  cancellation, per-file error reporting, partial-file cleanup, and lazy
  per-file decode/classify/process/write for unloaded batch members.
- macOS CI that runs the native engine tests and builds the app. The latest
  local native suite contains 164 tests.
- Real production-renderer comparison against the authoritative CPU path and an
  actual `AppModel` rapid-update scheduling integration test.

The remaining replacement work is automatic contour/crop detection,
perspective warp, dust detection/inpainting, film base density + color space
conversion, and flat-field calibration.

See [Native macOS Development](development/native-macos.md) for the
authoritative current step, progress, limitations, and next work.

## Legacy Python Application

The maintenance-only Python application still provides the complete historical
workflow:

- RAW and standard image import;
- automatic threshold-based crop detection and perspective correction;
- film-base, white-balance, exposure, saturation, and framing controls;
- intermediate RAW, threshold, contour, histogram, and full-preview views;
- individual and batch export;
- dust detection and inpainting.

It remains available for compatibility while those replacement gates are
completed, but it is not a target for new features. See
[Legacy Python Application](legacy-python.md).
