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
- Fast bounded previews from ImageIO thumbnails for standard images. Camera
  RAW files ignore the embedded JPEG and decode a colour-accurate demosaiced
  draft (about 640px, ~0.3s) so edits match RAW colour immediately. The selected
  file then upgrades to a ~4000px preview in about 4s, then a 1-pass
  full-resolution preview for pan and zoom. Lookahead decodes the next three
  unseen files at 3200px. Switching away discards the full-res buffer and keeps
  the ~4000px preview. Export retains the selected file's last three-pass
  decode so a settings-only re-export skips unpack and demosaic. Other files
  still decode independently. **Load RAW Preview** skips ahead to the
  selected-file 1-pass decode.
- A visual **Scans** sidebar with independently bounded 192px thumbnails,
  filenames, edit/cache/export state, native multi-selection, and stack badges.
  Camera RAW rows use the embedded JPEG with a simple invert; standard images
  invert the ImageIO thumbnail. Thumbnail loading does not pin the larger
  interactive previews in memory.
- Automatic high-confidence detection of adjacent, same-size captures of the
  same negative. Repeated captures are proposed as an opt-in aligned stack:
  **Auto** selects exposure fusion when the measured bracket spans at least
  0.5 EV and otherwise uses exposure-normalized robust averaging for lower
  sensor noise. **HDR** and **Noise** can also be forced explicitly. Detection
  and alignment are exposure-invariant, reject low-texture or ambiguous
  frames, and currently correct translation only. The canvas upgrades from a
  bounded stack preview to full resolution while you inspect; export still
  rebuilds from the sources. An enabled stack exports once under its first
  capture's filename and settings. A failed full-resolution upgrade keeps the
  bounded preview and displays the failure beside the stack controls.
- A bounded Core Image/Metal correction preview fed by the 16-bit preview
  source, with latest-value-wins scheduling. This GPU path is the primary
  interactive target on supported MacBook Pro hardware; CPU rendering remains
  the correctness/fallback path.
- A native still-preview viewport with momentum trackpad/mouse-wheel panning,
  cursor-centered pinch magnification, Fit, zoom-in/out, and 100% preview-pixel
  commands. Image, dust, crop, straighten, and perspective overlays share the
  same viewport transform.
- An on-canvas warning identifies embedded camera JPEGs when RAW colour is
  unavailable, and an aligned-stack badge appears when a stack preview is
  showing. A small loading bar stays on the first 640px draft until the
  ~4000px preview arrives; later sharpening pops in without a resolution label.
- Optional AVFoundation live camera preview when macOS exposes the camera or
  capture adapter as a video device. The live toolbar can invert a negative
  preview and adjust exposure and saturation; captured stills still use the
  16-bit import and export pipeline.

### Film Processing And Editing

- Automatic initial classification as color negative, B&W negative, or slide,
  without overwriting saved per-file choices. Orange-mask C-41 selects the
  generic Camera Raw colour curve; cyan/purple masks such as Harman Phoenix II
  select the **Darkroom** conversion with Harman Phoenix II stock. A fourth
  film type, **Original**, skips inversion and tone/color corrections for
  crop-and-export of already positive images.
- A goal-oriented **Film & Conversion** panel replaces the former nested
  profile menus. Choose the scan type first, then choose **Natural** for a
  reference-based starting point, **Darkroom** for film-and-paper rendering,
  **Classic** for the original exponent response, or **Bypass** for comparison.
  Stock and paper choices appear as visible, described options only when they
  apply; technical channel mixing remains in a clearly labeled advanced area.
- A default color-negative inversion calibrated from paired RAF/JPEG/XMP
  Camera Raw edits. It uses a half-strength per-frame exposure anchor and a
  quarter-strength channel-ratio anchor: enough adaptation to keep differently
  exposed negatives usable without forcing mixed-light and dusk frames fully
  neutral. The former RawTherapee-compatible exponent rendering remains
  available through the **Classic** conversion.
- Natural conversion offers four measured color-negative starting looks after
  the Balanced default: fresh Fujicolor 400 (eight fit references plus three
  validation additions), expired Fujicolor 200 (one reference), CineStill 800T
  (two references), and Harman Phoenix II (twelve references). The Fuji 200
  and CineStill fits remain experimental; the Harman look is leave-one-frame-out
  validated, but remains an explicit choice. Cyan/purple Phoenix scans
  auto-select the Darkroom conversion instead of this Natural look.
- Selectable **Darkroom** colour-negative profiles invert in log density
  (dye unmix, chroma-gated independent per-channel stretch, quadratic cast
  removal, H&D paper curve). This is the inversion that matches cyan/purple-mask
  stocks such as Harman Phoenix II. Built-in physical unmix stocks cover Generic
  C-41, Harman Phoenix II, Fujicolor 400/200/C200/Superia X-TRA 400/Natura 1600/
  Pro 400H, Kodak Portra 160/400/800, Gold 200, Ektar 100, Ultra Max 400,
  Aerocolor IV, and VISION3 250D/500T. Print character can be Neutral, Kodak
  Endura Premier, or Fujicolor Crystal Archive (RA4 dye coupling and channel
  gamma). Further stocks load as JSON from `NegativeDensityProfiles/`.
  Cyan/purple camera scans auto-select **Darkroom** with Harman Phoenix II, which
  uses a same-scene phone-JPEG unmix (different time, angle, and lighting) on
  Fujicolor Crystal Archive paper. Camera-scan rebate is inset 20% during
  analysis so sprocket holes do not crush the invert. These profiles are a
  physical rendering model, not a Camera Raw LUT fit.
- An optional capture-aware density pipeline with film-base measurement,
  flat-field calibration, capture/stock/roll profiles, and a 3x3-plus-offset
  density-correction slot stored in capture profiles. An offline
  fitter scores candidate corrections against frame-level held-out samples;
  no stock-specific matrix is built in without measured evidence.
- A neutral-preserving six-control dye-crossover matrix for color negatives.
  It corrects cross-channel dye contamination in linear light before tone,
  curves, and grading, and works with basic, power-law, physical density-print,
  and measured-density inversion. The neutral default leaves existing scans unchanged.
- Semantic Exposure, Brightness, Contrast, Highlights, Shadows, Temperature,
  Tint, Saturation, and Vibrance controls. Tone response is calibrated to the
  active inversion pipeline, with finer slider control around neutral.
- Smooth shape-preserving overall and per-channel curves plus shadow, midtone,
  and highlight color wheels. Enabling a new curve starts from identity, and
  curve points remain ordered while editing. B&W offers an overall **Tone**
  curve in Natural, Classic, and Bypass, with matching preview/export behavior;
  individual color-channel curves remain available for color film types.
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
- Natural B&W uses a paired RAW/JPEG/XMP-calibrated decreasing curve, full
  per-frame exposure anchoring, and a negative-side exposure control. Its
  visible starting looks are Balanced and Shanghai GP3, fitted from six paired
  references; Classic preserves the former B&W power-law rendering.
- Natural color likewise uses paired Camera Raw color curves and a negative-side
  exposure control. Its visible starting looks are Balanced plus the measured
  stock references above; Classic retains the former scene-median-normalized
  exponent rendering for existing looks.
- Named presets and versioned system-clipboard copy/paste, with a one-step
  remove action that restores the adjustments from before the last applied
  preset while retaining frame-specific geometry.
- A built-in **Kodachrome-like Auto** look keeps the standard color-negative
  inversion, then derives a per-frame tone curve from a bounded center-frame
  analysis and adds modest protected saturation/vibrance. It preserves the
  current rotation, flip, straighten, and crop geometry.
- Experimental **Prototype Looks** (Night Cinema, Golden Cream, Daylight Print,
  Blue Hour) use the same adaptive-curve inversion, with tone envelopes and
  split-tones sampled from finished JPEGs rather than paired emulsion
  measurements. They are starting points, not stock detection.
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
- Enabled scan stacks use the first capture's settings and filename, and count
  as one export item while the other captures remain available in the sidebar.
- Configurable 2/4/8/16/32-session preview cache (**Files kept ready**, default
  8) and forward lookahead of the next three unseen files.
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
- Full-resolution RAW decode one file at a time during export. The selected
  file's last three-pass decode is kept for settings-only re-export and dropped
  on selection change.
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
- Camera-scan RAW browsing first bins a ~640px colour-accurate draft, then
  upgrades the selected file to a ~4000px preview in about 4s, then a
  1-pass full-sensor preview. Unseen neighbours prefetch at 3200px; unused
  full-res buffers demote back to inspect size. Export retains the selected
  file's last three-pass decode for settings-only re-export and drops it on
  selection change. Other files still decode independently.
- Sidebar order remains import order. Manual reordering is unavailable and is
  not a first-release gate unless the roll workflow demonstrates a need.
- Repeated-capture proposals are limited to adjacent, same-size imports and
  translation-only alignment. Detection is conservative and opt-in; low-detail
  or ambiguous captures remain separate. A loaded flat field must be cleared
  before stacking because sensor-coordinate correction is not yet applied per
  capture before alignment.
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
