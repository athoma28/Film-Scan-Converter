# Features

This page describes current user-visible behavior. It does not list planned
features or internal implementation milestones. See the
[native development status](development/native-macos.md) for verified gaps and
the [roadmap](improvements/MacOS-Native-Roadmap.md) for delivery order.

## Native Swift/macOS Application

The native application is the primary product and the only target for new
features.

### Import And Preview

- Drag/drop, file picker, and Finder Open With import.
- Standard PNG, JPEG, BMP, and TIFF decoding.
- LibRaw-backed camera RAW decoding.
- Fast bounded previews from ImageIO thumbnails for standard images and
  embedded thumbnails for camera RAW files. An explicit **Load RAW Preview**
  action replaces an embedded thumbnail with a demosaiced, RAW-calibrated
  preview up to 2400px when color or detail needs closer inspection;
  full-resolution decoding remains reserved for export.
- A bounded Core Image/Metal correction preview fed by the 16-bit preview
  source, with latest-value-wins scheduling. This GPU path is the primary
  interactive target on supported MacBook Pro hardware; CPU rendering remains
  the correctness/fallback path.
- A native still-preview viewport with momentum trackpad/mouse-wheel panning,
  cursor-centered pinch magnification, Fit, zoom-in/out, and 100% preview-pixel
  commands. Image, dust, crop, straighten, and perspective overlays share the
  same viewport transform.
- An on-canvas badge identifies embedded RAW, demosaiced RAW-detail, and bounded
  standard-image preview sources and reports the displayed pixel dimensions.
- Optional AVFoundation live camera preview when macOS exposes the camera or
  capture adapter as a video device. The live toolbar can invert a negative
  preview and adjust exposure and saturation; captured stills still use the
  16-bit import and export pipeline.

### Film Processing And Editing

- Automatic initial classification as color negative, B&W negative, or slide,
  without overwriting saved per-file choices. A fourth film type, **Original**,
  skips inversion and tone/color corrections for crop-and-export of already
  positive images.
- A default color-negative inversion calibrated from paired RAF/JPEG/XMP
  Camera Raw edits. It uses a half-strength per-frame exposure anchor and a
  quarter-strength channel-ratio anchor: enough adaptation to keep differently
  exposed negatives usable without forcing mixed-light and dusk frames fully
  neutral. The former RawTherapee-compatible exponent rendering remains
  available as **Color Negative (Legacy)**.
- Four selectable alternate color-negative profiles use separate measured
  base anchors and curves: fresh Fuji 400 (eight fit references plus three
  validation additions), expired Fuji 200 (one reference), CineStill 800T
  (two references), and Harman Phoenix II (twelve references). The Fuji 200
  and CineStill fits remain experimental; Harman is leave-one-frame-out
  validated, but remains an explicit choice and does not replace the generic
  default.
- An optional capture-aware density pipeline with film-base measurement,
  flat-field calibration, capture/stock/roll profiles, and a 3x3-plus-offset
  density-correction slot stored in capture profiles. An offline
  fitter scores candidate corrections against frame-level held-out samples;
  no stock-specific matrix is built in without measured evidence.
- A neutral-preserving six-control dye-crossover matrix for color negatives.
  It corrects cross-channel dye contamination in linear light before tone,
  curves, and grading, and works with basic, power-law, and measured-density
  inversion. The neutral default leaves existing scans unchanged.
- Semantic Exposure, Brightness, Contrast, Highlights, Shadows, Temperature,
  Tint, Saturation, and Vibrance controls. Tone response is calibrated to the
  active inversion pipeline, with finer slider control around neutral.
- Smooth shape-preserving overall and per-channel curves plus shadow, midtone,
  and highlight color wheels. Enabling a new curve starts from identity, and
  curve points remain ordered while editing.
- Near-zero holder-mask pixels that invert into clipped highlights are rendered
  as neutral white after adjustments in both preview and export.
- Automatic frame detection plus a built-in four-corner perspective tool:
  drag targeting-reticle handles onto the film edges, using the 100×100-pixel
  loupe for exact corner placement and the drawn 4×4 grid for alignment.
  Parallel-edge assist softly favors the common trapezoidal case while Option
  dragging remains fully free. The resulting perspective warp is independent
  from the later crop and is applied in preview and export. A separate
  Photoshop-style straighten tool takes two points along
  an edge and automatically makes the guide horizontal or vertical. A simple
  drag-box crop then trims the current straightened canvas. The inspector shows
  the resulting full-resolution pixel dimensions even though the canvas uses a
  bounded preview. Rotation, horizontal flip, white frame, and aspect-ratio
  padding remain available.
- Original/corrected toggle that retains the current viewport and magnification.
- Grade diagnostics for sampled display clipping.
- Non-destructive, orientation/crop-aligned dust-candidate overlay. Detection
  does not remove dust from preview or export.

### Batch And Settings Workflow

- Per-file correction settings persisted across launches.
- Standard macOS Edit-menu Undo/Redo (Command-Z / Command-Shift-Z) for tone,
  color, inversion, curves, grading wheels, crop, straighten, perspective,
  rotation, flip, output frame, reset, paste, and profile/preset application.
  Histories are isolated per file, slider/curve/wheel/perspective drags
  coalesce to one step, and the currently restored state is saved even though
  transient history starts empty after relaunch.
- User film-stock profiles preserve the current negative rendering, calibrated
  color variant, exponents, dye-crossover correction, density response, and
  display rendering settings.
  The app does not use the alternate base fits as automatic stock detection or
  as validated density-correction matrices.
- The generic B&W profile uses a paired RAW/JPEG/XMP-calibrated decreasing
  curve, full per-frame exposure anchoring, and a negative-side exposure
  control. The former B&W power-law rendering remains selectable as
  **Generic B&W Negative (Legacy)**. A stock-specific
  **Alternate — Shanghai GP3** curve is fitted from six paired references and
  uses a half-strength exposure anchor for a softer per-frame response.
- The generic color profile likewise uses paired Camera Raw color curves and a
  negative-side exposure control. Its legacy profile retains the former
  scene-median-normalized exponent rendering for existing looks.
- Named presets and versioned system-clipboard copy/paste, with a one-step
  remove action that restores the adjustments from before the last applied
  preset while retaining frame-specific geometry.
- A built-in **Kodachrome-like Auto** look keeps the standard color-negative
  inversion, then derives a per-frame tone curve from a bounded center-frame
  analysis and adds modest protected saturation/vibrance. It preserves the
  current rotation, flip, straighten, and crop geometry.
- Manual crop updates the preview canvas immediately. Re-entering Crop reveals
  the whole straightened canvas for a replacement selection, and Reset Crop
  removes the committed crop.
- Apply the current look to the import-ordered multi-selection or to all open
  files while preserving each target's crop, orientation, perspective, and
  measured film-base state.
- Previous/Next scan commands follow import order, collapse a multi-selection
  to the adjacent file, and fit the new preview. Option-Command-Up/Down work
  even when the inspector has keyboard focus.
- Edited, preview-ready, active-export, and pending-export indicators in the
  browser.
- Configurable 2/4/8/16/32-session preview cache and forward lookahead.
- Immediate Edit/Grade/Export inspector switching.

### Export

- 16-bit TIFF with optional LZW compression and an embedded sRGB profile.
- 8-bit JPEG with configurable quality and an embedded sRGB profile.
- 16-bit lossless PNG with an embedded sRGB profile.
- Processed 16-bit RGB DNG in a standards-valid TIFF/DNG container, encoded as
  output-referred linear sRGB. This is not untouched sensor RAW; TIFF is the
  preferred 16-bit interchange format for software with limited DNG support.
- Individual, ordered multi-selection, and lazy memory-bounded Export All
  workflows.
- Full-resolution RAW re-decode one file at a time during export.
- Collision-safe destination names, per-file errors, and cooperative
  cancellation at safe decode/correction/geometry/write boundaries. An active
  synchronous LibRaw or writer call finishes before cancellation advances.
- PNG uses a staged commit; every format removes a failed destination so a
  partial output is not presented as successful.
- Append selected files to an active sequential export with active/pending
  status. Duplicate source jobs are accepted, collision-safe names preserve
  every copy, and each addition snapshots its own format, destination,
  compression, frame, and aspect-ratio settings.

### Packaging And Verification

- Self-contained app and ZIP assembly with embedded non-system libraries.
- App icon, normal menu/Dock identity, and image/camera-RAW document
  registration.
- Hardened-runtime Developer ID signing support.
- Local validation of both the assembled app and extracted archive.
- Automated native tests and app build on macOS CI.

## Native Limitations

- No applied dust removal or Telea inpainting.
- **Load RAW Preview** still unpacks the RAF and runs 1-pass X-Trans at full
  sensor size, then downscales to 2400px. Export always re-decodes the
  full-resolution three-pass path and discards the buffer.
- Sidebar order remains import order. Manual reordering is unavailable and is
  not a first-release gate unless the roll workflow demonstrates a need.
- No lens-distortion model or calibrated correction for film-plane/sensor-plane
  non-alignment beyond the current perspective crop.
- The real RAW test corpus is Fujifilm X-Trans-focused and partly local-only;
  the Bayer RCD path lacks a committed real-file gate.
- Camera-scan ISO denoise/sharpen behavior is a bounded native policy, not an
  exact RawTherapee kernel port.
- TIFF, JPEG, and PNG are explicitly tagged as sRGB. DNG records its distinct
  output-referred linear-sRGB color contract in DNG metadata rather than an ICC
  profile.
- Stock/capture calibration research and named-stock fitting are intentionally
  parked until the project owner explicitly asks to resume them.
- Standard images with alpha are rejected because four-channel processing has
  not been defined.
- The technical beta is ad-hoc signed, Apple Silicon-only, and requires the
  normal Control-click **Open** confirmation on first launch. A Developer
  ID-signed/notarized build and independent clean-machine validation remain
  future distribution-hardening work.

## Legacy Python Application

The maintenance-only Python application retains the historical cross-platform
workflow, including automatic dust detection and inpainting. It remains
available for compatibility and legacy users but receives no new product
features. See [Legacy Python Application](legacy-python.md).
