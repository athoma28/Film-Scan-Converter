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
- Automatic threshold-based film-frame detection, normalized rotated crop
  geometry, and perspective-corrected preview/export through the shared
  processing entry point.
- Threshold generation (grayscale conversion, binary thresholding, morphological
  erosion) matching Python output exactly.
- Native dust-mask detection matching frozen Python/OpenCV output, including
  ignored-border percentile sampling, morphology, and contour-area filtering.
  Telea inpainting and app integration remain pending.
- White balance coefficient adjustment matching Python float64 output exactly.
- Saturation adjustment via RGB↔HSV conversion matching Python output within
  documented ≤1 LSB tolerance, including Python-equivalent clipping of
  white-balanced highlights before HSV conversion.
- Primary color-negative processing now uses protected linear Rec.2020
  Temperature/Tint, Saturation, and separate Vibrance controls with luminance,
  highlight, gamut, and hue safeguards. The legacy RGB/HSV operators remain for
  compatibility fixtures.
- Exposure adjustment matching Python float32 rounding exactly.
- `shrink_box` coordinate math for crop-box adjustment.
- Float64 NPY fixture infrastructure for intermediate pipeline stages.
- Film-negative inversion using RawTherapee's power-law exponent model, with reference
  resolution from 20%-border-cut channel medians to RawTherapee's `1/24`
  linear output reference. Per-channel
  exponent model:
  `output = multiplier × pixel^-(greenExp × ratio)`. Color Negative preset
  (RedRatio=1.36, GreenExp=1.5, BlueRatio=0.86) and Black & White preset (all
  ratios=1.0) matching RawTherapee's `Film Negative.pp3` and `Film Negative -
  Black and White.pp3`. CPU (Double) and production Metal CIKernel processing
  parity. SwiftUI controls with preset picker and per-channel
  ratio/exponent sliders.
- Film-negative reference resolution and inversion in linear Rec.2020 after
  decoding to sRGB, followed by conversion back to display sRGB. This is not a
  direct camera-to-Rec.2020 transform.
- Camera-scan RAW metadata and bounded ISO-tier processing: low-ISO sharpening
  or medium/high-ISO denoising. These filters are native approximations, not
  ports of RawTherapee's full denoise and capture-sharpening kernels.
- Engine support for RCD on full-resolution Bayer decode and three-pass
  Markesteijn interpolation on full-resolution X-Trans decode. Interactive RAW
  previews stay half-size; RAW export re-decodes one file at a time at full
  resolution. The available RAF corpus is X-Trans, so it does not exercise RCD.
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
  user-selectable 2/4/8/16/32-session decoded-preview cache with matching forward
  predecode lookahead.
- Automatic per-file correction persistence across launches using versioned,
  atomic settings storage with safe recovery from corrupt files.
- Named correction presets with versioned atomic persistence, plus copy/paste
  through a versioned system-clipboard payload. Applying a look preserves the
  target scan's crop/orientation and measured film-base state.
- User-edit markers independent of cache state, apply-current-settings-to-all,
  immediate target-median refresh after paste, and append-selected during an
  active sequential export.
- A shared unclamped linear adjustment seam with bounded robust statistics,
  protected Temperature/Tint/Saturation/Vibrance controls, and safe semantic
  Exposure/Brightness/Contrast/Highlights/Shadows controls.
- Manual or automatic unexposed-film-edge measurement, optional flat-field
  calibration, roll-profile storage, and density-pipeline preview/export.
- Render instrumentation with `os_signpost` profiling markers and published
  snapshot/display/drop counters.
- TIFF (16-bit, optional LZW compression), JPEG (8-bit, configurable quality),
  PNG (16-bit lossless), and DNG (processed 16-bit RGB in a valid TIFF container)
  export with individual and batch-all workflows, background processing,
  cancellation, per-file error reporting, partial-file cleanup, collision-safe
  destination naming, and lazy per-file decode/classify/process/write for
  unloaded batch members.
- macOS CI that runs the native engine tests and builds the app. The 500-render
  performance benchmark is opt-in.
- Reproducible self-contained app and ZIP assembly with embedded non-system
  dependencies, bundle-relative load paths, hardened-runtime signing support,
  and validation of both the assembled app and the extracted archive copy.
- Real production-renderer comparison against the authoritative CPU path and an
  actual `AppModel` rapid-update scheduling integration test.

The primary remaining processing replacement is Telea dust inpainting and its
preview/export/app integration.
Fixture independence, Developer ID notarization, Gatekeeper/clean-machine
release validation, and deferred preview-surface work also remain.

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

It remains available for dust handling and compatibility while the remaining
retirement gates are completed, but it is not a target for new features. See
[Legacy Python Application](legacy-python.md).
