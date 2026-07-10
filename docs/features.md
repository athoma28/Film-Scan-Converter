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
- Fast bounded provisional previews for large standard images and embedded RAW
  thumbnails, followed by an authoritative background replacement with stable
  orientation.
- A bounded 16-bit Core Image/Metal correction preview with latest-value-wins
  scheduling. This GPU path is the primary interactive target on supported
  MacBook Pro hardware; CPU rendering remains the correctness/fallback path.
- Optional AVFoundation live camera preview when macOS exposes the camera or
  capture adapter as a video device.

### Film Processing And Editing

- Automatic initial classification as color negative, B&W negative, or slide,
  without overwriting saved per-file choices.
- RawTherapee-compatible power-law film-negative inversion.
- An optional capture-aware density pipeline with film-base measurement,
  flat-field calibration, and capture/stock/roll profiles.
- Semantic Exposure, Brightness, Contrast, Highlights, Shadows, Temperature,
  Tint, Saturation, and Vibrance controls.
- Overall and per-channel curves plus shadow, midtone, and highlight color
  wheels.
- Automatic frame detection plus a built-in four-corner perspective tool:
  drag the canvas handles onto the film edges, use the drawn 4×4 grid to align
  the frame, and non-destructively straighten that quadrilateral in preview
  and export. A separate Photoshop-style straighten tool takes two points along
  an edge and automatically makes the guide horizontal or vertical. A simple
  drag-box crop then trims the current straightened canvas. The inspector shows
  the resulting full-resolution pixel dimensions even though the canvas uses a
  bounded preview. Rotation, horizontal flip, white frame, and aspect-ratio
  padding remain available.
- Original/corrected toggle.
- Grade diagnostics for sampled display clipping.
- Non-destructive, orientation/crop-aligned dust-candidate overlay. Detection
  does not remove dust from preview or export.

### Batch And Settings Workflow

- Per-file correction settings persisted across launches.
- Named presets and versioned system-clipboard copy/paste.
- Apply the current look to all open files while preserving each target's crop,
  orientation, and measured film-base state.
- Edited and preview-ready indicators in the browser.
- Configurable 2/4/8/16/32-session preview cache and forward lookahead.
- Immediate Edit/Grade/Export inspector switching.

### Export

- 16-bit TIFF with optional LZW compression.
- 8-bit JPEG with configurable quality.
- 16-bit lossless PNG.
- Processed 16-bit RGB DNG in a valid TIFF/DNG container. This is not untouched
  sensor RAW.
- Individual and lazy memory-bounded Export All workflows.
- Full-resolution RAW re-decode one file at a time during export.
- Collision-safe destination names, per-file errors, cancellation between
  synchronous file operations, atomic staging/cleanup, and protection against
  misleading partial outputs.
- Append the selected file to an active sequential export with duplicate
  rejection and active/pending status.

### Packaging And Verification

- Self-contained app and ZIP assembly with embedded non-system libraries.
- App icon, normal menu/Dock identity, and image/camera-RAW document
  registration.
- Hardened-runtime Developer ID signing support.
- Local validation of both the assembled app and extracted archive.
- Automated native tests and app build on macOS CI.

## Native Limitations

- No applied dust removal or Telea inpainting.
- No undo/redo, zoom/pan, ordered multi-selection, Export Selected, or sidebar
  reordering yet.
- No lens-distortion model or calibrated correction for film-plane/sensor-plane
  non-alignment beyond the current perspective crop.
- The real RAW test corpus is Fujifilm X-Trans-focused and partly local-only;
  the Bayer RCD path lacks a committed real-file gate.
- Camera-scan ISO denoise/sharpen behavior is a bounded native policy, not an
  exact RawTherapee kernel port.
- Standard images with alpha are rejected because four-channel processing has
  not been defined.
- The app has not completed Developer ID notarization, Gatekeeper assessment,
  or clean-machine installation validation and is not yet claimed as a
  generally distributable release.

## Legacy Python Application

The maintenance-only Python application retains the historical cross-platform
workflow, including automatic dust detection and inpainting. It remains
available for compatibility and legacy users but receives no new product
features. See [Legacy Python Application](legacy-python.md).
