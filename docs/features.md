# Features

This inventory describes the native application shipped in 0.2.0 Beta 2 and
the current development source. See [Installation](installation.md), the
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
- A separate thumbnail cache supplies 192px sidebar images. RAW thumbnails use
  embedded JPEGs; the main RAW canvas uses demosaiced previews when available.
- Core Image/Metal correction preview with latest-value-wins scheduling and a
  deterministic CPU fallback. Preview sessions are bounded by count and bytes;
  the default count is eight. No cache-size control appears in the current UI.
- Native Fit, momentum pan, cursor-centered pinch, step zoom, and 100% current
  preview pixels. Image and editing/dust overlays share the viewport transform.
- Original comparison preserves geometry, pan, and magnification. Source-tier
  upgrades preserve the viewed region. New selections return to Fit.
- Embedded-JPEG warning when RAW colour is unavailable, first-draft loading
  indicator, and an aligned-stack badge when appropriate.
- Optional AVFoundation live preview with invert, exposure, and saturation.

## Develop

- **Film & Inversion**: color negative, B&W negative, slide, and Original scan
  types, with Natural, Darkroom, Classic, and Bypass negative conversion.
  Classification initializes new scans without overwriting saved choices.
- **Natural**: paired RAW/JPEG/XMP reference curves with exposure adaptation.
  Color uses partial exposure and channel-ratio anchors; B&W uses full exposure
  anchoring. Negative Exposure adjusts the negative before inversion.
- Natural color starting looks: Balanced, Fujicolor 400, Fuji 200 Expired,
  CineStill 800T, and Harman Phoenix II. Fuji 200/CineStill remain experimental.
  B&W offers Balanced and Shanghai GP3. These are explicit starting looks, not
  automatic stock identification or universal stock characterizations.
- **Darkroom**: log-density dye unmix, chroma-gated channel bounds, cast removal,
  and an H&D paper curve. Cyan/purple masks select Harman Phoenix II with
  Fujicolor Crystal Archive. Neutral and Kodak Endura Premier papers are also
  available. The stock catalog includes generic C-41, Phoenix, Fujicolor, Portra,
  Gold, Ektar, Ultra Max, Aerocolor, and VISION3 variants; additional profiles
  load from `NegativeDensityProfiles/`. Provenance is recorded in each profile.
- **Classic**: exponent-based negative inversion. **Original** skips inversion
  and tone/color corrections while retaining geometry and export.
- **Tone & Light**: exposure, brightness, contrast, highlights, shadows, smooth
  ordered curves, and sampled display clipping. B&W supports overall tone
  curves on CPU and GPU; per-channel curves are for color film types.
- **Color & Balance**: temperature, tint, saturation, vibrance, and shadow,
  midtone, and highlight color wheels. Near-zero holder pixels that invert to
  clipped highlights are neutralized in both preview and export.
- **Looks & Presets**: saved presets, Kodachrome-like Auto, and experimental
  Prototype Looks. Restore Before reverses the last preset application while
  preserving frame-specific geometry.

## Geometry And Calibration

- Rotation, horizontal flip, two-point horizontal/vertical straighten, Auto
  Frame, four-corner perspective, and a separate manual canvas crop.
- Perspective reticles, a 100×100-pixel loupe, grid, and optional parallel-edge
  assistance. The warp corrects one planar quadrilateral.
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
  correction is supplied. This is separate from Natural curves and Darkroom unmix.

## Rolls, Stacks, And Settings

- Scans sidebar with multi-selection, import-ordered Previous/Next Scan,
  edited/preview-ready/export markers, and stack badges.
- Per-file persisted corrections and session-local Undo/Redo. Continuous slider,
  curve, wheel, and perspective gestures coalesce into one history entry.
- Correction copy/paste and selected/all look application preserve destination
  geometry and measured film base. User film-response profiles retain inversion,
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
anchor name. Sheets use bounded demosaiced RAW previews, preserve import order,
and support progress, cancellation, collision-safe naming, and failure cleanup.
They show committed crop/corrections, independently of Original comparison or
an open geometry editor. Export borders and aspect padding are not included.

Local app/ZIP packaging embeds dependencies, licenses, icon/document registration,
and a library manifest; it validates the app and extracted archive. Developer
ID/notarization support exists, but the published beta is ad-hoc signed.

## Limitations

Native dust removal, manual sidebar reordering, lens-distortion modeling, and
vendor-specific tethering are absent. Stacking handles translation only and is
disabled with a loaded flat field. Alpha-channel standard images are rejected.
Processed DNG support varies by reader; TIFF is the broad-interchange option.

Measured-density processing uses CPU fallback. RAW identity fixtures are
same-machine and X-Trans-focused; Bayer lacks a committed real-file gate.
Broader photographic/roll/stack judgment, independent-Mac output review, and
notarized distribution remain open. Further named-stock calibration and ML are
parked under the [roadmap](improvements/MacOS-Native-Roadmap.md).

The [legacy Python app](legacy-python.md) retains automatic dust removal and
cross-platform/ART use under a maintenance-only policy.
