# Features

This inventory describes the current native application, including downloadable
0.2.0 Beta 3. See [Installation](installation.md), the
[usage guide](how-to-use.md), and
[development status](development/native-macos.md) for instructions and
verification.

## Import And Preview

- File picker, drag/drop, and Finder Open With for camera RAW and standard
  TIFF, PNG, JPEG, and BMP images.
- ImageIO standard-image previews bounded to 1000px. RAW browsing uses a
  colour-accurate demosaiced draft, selected-file inspect and full-sensor 1-pass
  previews, and lookahead for the next three unseen files. Actual sizes depend
  on [CFA binning](development/xtrans-preview-mosaic-binning.md).
- **Load RAW Preview** goes straight to full-sensor detail, including while an
  automatic inspect preview is running.
- A separate thumbnail cache supplies 192px sidebar images. RAW thumbnails use
  embedded JPEGs; the main RAW canvas uses demosaiced previews when available.
- Core Image/Metal correction preview with latest-value-wins scheduling and a
  deterministic CPU fallback. Preview sessions are bounded by count and bytes;
  the default count is eight. Full-resolution previews and completed corrections
  survive selection changes. Cache memory scales to 2 GiB on 16 GiB Macs or
  3 GiB on 24 GiB Macs; memory pressure releases background entries. No cache-size
  control appears in the current UI. Up to two neighbouring RAWs prepare at full
  detail in the background when space permits.
- At whole-image zoom, supported point-control gestures on a selected
  full-sensor RAW can use a retained 2048px source without changing the logical
  canvas. The preview can render that source on either the GPU or CPU path;
  zoomed GPU inspection instead renders the visible region from the full source,
  while CPU fallback processes the full source. Releasing the gesture publishes
  exact full-source detail. Export is unchanged.
- Native Fit, momentum pan, cursor-centered pinch, step zoom, and 100% current
  preview pixels. Settled images pan and zoom without repeating corrections.
  Image and editing/dust overlays share the viewport transform.
- Original comparison preserves geometry, pan, and magnification. Source-tier
  upgrades preserve the viewed region. New selections return to Fit.
- Embedded-JPEG warning when RAW colour is unavailable, first-draft loading
  indicator, and an aligned-stack badge when appropriate.
- Optional AVFoundation live preview with invert, exposure, and saturation.

## Develop

- **Film Base**: Color C-41, color cyan-mask, B&W negative, Slide, or Original.
  Classification guesses new scans and applies the first recommended factory
  look as a starting point; the user can override either choice. Each base has
  one invert. Color negatives use density-print inversion with a generic C-41
  or cyan-mask unmix and a neutral print response. Looks never change film base.
- **Presets**: a compact menu of recommended, factory, and saved looks. Each look is a
  snapshot of the public sliders, curves, and wheels. Apply assigns those
  values on the existing preview path. The sliders jump to show the recipe;
  further edits show Custom. Command-Z undoes apply. Save current stores the
  same snapshot, identifies replacement names, and retains the name after a
  failed save. Reset Adjustments preserves film base, calibration, and framing.
- Factory looks: Clean Invert, Soft People, Punchy Print, Warm, Cool, Foliage,
  Night Lift, B&W Print, and B&W Soft. These are creative starting points, not
  measured stock or paper simulations.
- **Tone & Light**: exposure, brightness, contrast, broad highlights/shadows,
  focused whites/blacks, smooth ordered curves, and sampled display clipping.
  B&W supports overall tone
  curves on CPU and GPU; per-channel curves are for color film types.
- **Color & Balance**: temperature, tint, saturation, vibrance, color wheels,
  Shadow Floor, Midtone Level, and Highlight Ceiling beneath the wheels,
  and, on color negatives, foliage recovery, cast cleanup, and color
  separation. Near-zero holder pixels that invert to clipped highlights are
  neutralized in both preview and export.

## Geometry And Calibration

- Rotation, horizontal flip, two-point horizontal/vertical straighten, Auto
  Frame, four-corner perspective, and a separate manual canvas crop.
- Perspective reticles, a 100×100-pixel loupe, projective grid, and optional parallel-edge
  assistance. Frame Ratio restores known proportions such as 3:2; Automatic
  estimates from the edges. Arrow keys move a selected corner one source pixel,
  Shift ten; Option disables snapping. Border shading shows the retained frame.
  The warp corrects one planar quadrilateral, before straighten/manual crop.
- Manual crop handles, box movement/replacement, and an uncropped editing
  canvas. Clearing manual crop preserves upstream geometry; changing upstream
  geometry clears the dependent crop. Preview, export, and full-output dimension
  prediction share geometry semantics.
- Fixed manual-crop ratios: 1:1, 3:2, 4:3, 5:4, 16:9, and portrait equivalents.
  Drawing and resize handles preserve the ratio; Free unlocks the current box.
  Each scan saves its ratio with its crop, including Undo/Redo and relaunch.
- Diagnostic dust-candidate overlay aligned to the displayed geometry.
- **Calibrate**: film-base edge detection/manual sampling, flat field,
  measured-density conversion, and persisted capture/film-response/roll profiles.
- Neutral-preserving six-control dye crossover in Advanced Color Science for
  color negatives, applied before tone, curves, and grading.
- Capture profiles can store an affine density correction. The offline fitter
  has synthetic and held-out validation machinery; no validated built-in capture
  correction is supplied. Historical Natural curves and stock unmix profiles
  remain engine/provenance data; they are not current Develop pickers.

## Rolls, Stacks, And Settings

- Scans sidebar with multi-selection, Previous/Next Scan in sidebar order,
  session-local up/down reordering, edited/preview-ready/export markers, and
  stack badges.
- Per-file persisted corrections and session-local Undo/Redo. Continuous slider,
  curve, wheel, and perspective gestures coalesce into one history entry.
  Background saves coalesce rapid edits; normal quit waits for pending saves.
- Correction copy/paste and selected/all look application transfer public
  adjustments and preserve destination geometry, film base, and calibration.
  Version-one presets migrate to these snapshots; the first save/delete keeps
  the original library as a backup. User film-response profiles retain inversion,
  crossover, density, and display settings.
- Opt-in repeated-capture proposals for adjacent, same-size scans. Translation
  registration rejects low-texture or ambiguous matches. Auto selects HDR when
  exposure spread is at least 0.5 EV, otherwise Noise; either can be forced.
- Bounded-to-full-resolution stack preview and full-resolution export use
  original-capture statistics and exposure weights, with temporary row-band
  storage. Errors retain a usable preview and remain visible. An enabled stack
  exports once under the first capture's name and settings.

## Export And Packaging

| Format | Output |
|---|---|
| TIFF | 16-bit sRGB; no compression by default, optional LZW. |
| JPEG | 8-bit sRGB; configurable quality. |
| PNG | 16-bit lossless sRGB. |
| DNG | Processed 16-bit RGB with output-referred linear-sRGB metadata, not sensor RAW. |

Export is sequential, supports selected/all files and appending duplicate jobs,
and snapshots each job's output options. Names are collision-safe, errors are
per-file, and cancellation occurs at safe boundaries. PNG uses staged commit;
all formats clean up failed destinations. The selected RAW retains its last
three-pass decode for settings-only re-export and drops it on selection change.

**Contact Sheet** saves selected or all scans to a Letter-size PDF, with 12
corrected previews per page, filenames, and page numbers. Settings are captured
when the sheet starts; each enabled stack contributes one merged tile under its
anchor name. Sheets use bounded demosaiced RAW previews, preserve sidebar order,
and support progress, cancellation, collision-safe naming, and failure cleanup.
They show committed crop/corrections, independently of Original comparison or
an open geometry editor. Export borders and aspect padding are not included.

Local app/ZIP packaging embeds dependencies, licenses, icon/document registration,
and a library manifest; it validates the app and extracted archive. Developer
ID/notarization support exists, but the published beta is ad-hoc signed.

## Limitations

Native dust removal, lens-distortion modeling, and vendor-specific tethering
are absent. Stacking handles translation only and is
disabled with a loaded flat field. Alpha-channel standard images are rejected.
Processed DNG support varies by reader; TIFF is the broad-interchange option.

Measured-density processing uses CPU fallback. RAW identity fixtures are
same-machine and X-Trans-focused; Bayer lacks a committed real-file gate.
Broader photographic/roll/stack judgment, independent-Mac output review, and
notarized distribution remain open. Further named-stock calibration and ML are
parked under the [roadmap](improvements/MacOS-Native-Roadmap.md).

The [legacy Python app](legacy-python.md) retains automatic dust removal and
cross-platform/ART use under a maintenance-only policy.
