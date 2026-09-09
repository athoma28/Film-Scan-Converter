# How To Use

This guide describes the current native source. The downloadable
[0.2.0 Beta 1](https://github.com/athoma28/Film-Scan-Converter/releases/tag/v0.2.0-beta.1)
predates this inspector and some workflows. See [Installation](installation.md)
for source builds. Python instructions are in [Legacy Usage](legacy-usage.md).

## Import And Inspect

Open files with Command-O or drag RAW, TIFF, PNG, JPEG, or BMP scans into the
window. Choose a scan in the Scans sidebar. Command-click or Shift-click selects
multiple files; Previous/Next Scan moves through import order and fits the new
selection.

Camera RAW first displays a colour-accurate draft, then sharpens to an inspect
preview and full-sensor detail. You can edit while it loads. **Load RAW Preview**
skips ahead to full detail. A loading bar marks the first draft; a warning
identifies an embedded camera JPEG if RAW colour is unavailable.

Pan with a trackpad or mouse wheel, pinch to zoom, or use Fit and the zoom
buttons. **100% Preview Pixels** means one current-preview pixel per view point;
it corresponds to sensor pixels after the full-resolution upgrade. **Original**
compares the uncorrected image with matching geometry, pan, and magnification.
Perspective and film-base editors temporarily reveal the oriented source.

The inspector header reports **Full output** dimensions, including geometry and
export framing, rather than the current preview size.

## Develop

In **Film & Inversion**, review **Scan Type** and **Conversion Mode**. New scans
are classified automatically; saved choices are restored.

| Choice | Use |
|---|---|
| Original scan type | Positive images that need geometry/export without inversion or tone/color corrections. |
| Natural | Reference-derived negative curves with a Balanced default and optional stock starting looks. |
| Darkroom | Color-negative log-density inversion with film-stock and paper choices. Cyan/purple-mask scans automatically select Harman Phoenix II with Crystal Archive paper. |
| Classic | Exponent-based color or monochrome negative inversion. |
| Bypass | Compare without the selected negative conversion. |

Natural's stock alternatives are starting looks, not automatic stock detection.
Fuji 200 Expired and CineStill 800T remain experimental. Profile provenance and
validation limits are documented in [reference calibration](development/reference-negative-calibration.md).

Use **Tone & Light** for exposure, brightness, contrast, highlights, shadows,
and curves. Its clipping readout samples the displayed image. **Color & Balance**
provides temperature, tint, saturation, vibrance, and color wheels for color
film types. B&W uses an overall Tone curve; color-channel curves are restricted
to color film types. Positive **Negative Exposure** values in Natural darken
the resulting positive by adjusting the negative before inversion.

Edits save automatically for the source path. Command-Z and Command-Shift-Z
undo/redo per file; each continuous slider, curve, wheel, or perspective gesture
forms one step. Relaunch restores saved settings and starts fresh undo history.

Use **Looks & Presets** to apply a look, save a preset, or **Restore Before** the
last applied preset. Copy/paste buttons transfer corrections. The adjacent
ellipsis menu contains **Apply Look to Selected** and **Apply Settings to All
Open Files**; both preserve each destination's geometry and measured film base.

## Geometry

In **Orientation**, rotate or flip the image. **Straighten Edge…** accepts two
points on an edge and aligns it to the nearest horizontal or vertical axis.

In **Crop & Framing**:

- **Auto Frame** detects a film frame using the threshold controls. Read the
  status below the controls if no frame is found.
- **Perspective** exposes four corner reticles, a grid, and a magnified loupe.
  Drag to the film edges; hold Option to bypass parallel-edge assistance.
- **Manual Crop** reveals the full straightened canvas. Drag a rectangle, adjust
  its handles, drag inside to move it, or outside to replace it. Choose **Done**
  to display the cropped result. Use its **Clear** control to remove only the
  manual crop and retain earlier geometry.

Manual crop is expressed on the canvas created by earlier geometry. Changing
rotation, flip, straighten, automatic frame, or perspective invalidates that
manual crop. Clearing perspective also clears its dependent manual crop.
Finish those geometry choices before applying the final crop; Undo restores
an earlier edit when needed.

**Dust Mask** detects and displays candidates. It does not remove dust or export
the overlay. Applied removal is available in the legacy Python workflow.

## Calibrate

**Film Base (Rebate)** offers **Auto Detect Edge**, **Sample Area**, and
**Flat Field**. Measure a clear, unexposed film area; use a flat field captured
with the same setup. Status text explains detection or sampling failures.
Film-base measurement enables the measured-density conversion for negatives.

**Density Pipeline** and **Workflow Profiles** hold the capture, film-response,
and roll settings. **Advanced Color Science** provides neutral-preserving dye
crossover for color negatives. Use **Reset Dye Crossover** to restore its neutral
matrix. These specialized controls are optional; see [Features](features.md).

## Repeated Captures And Live Camera

Adjacent, same-size captures that confidently match may show an optional stack
card in Scans. Enable **Use aligned stack** after reviewing the proposal.
**Combine for: Auto** chooses HDR for an exposure bracket and Noise for
same-exposure captures; either mode can also be selected explicitly.

The canvas retains a usable preview while alignment and sharper tiers load.
An **Aligned stack preview** badge identifies the result. A failed full-resolution
upgrade keeps the bounded preview and reports the failure; toggle the stack off
and on to retry. Alignment handles translation only. Clear a loaded flat field
before stacking. An enabled stack exports once under its first capture's name
and settings, rebuilt from the original captures.

**Live Camera** works when macOS exposes the device through AVFoundation. Its
Invert Negative, Exposure, and Saturation controls affect live preview.

## Export

Choose **File** format, **Frame** border/aspect ratio, and **Destination** folder
on the Export page. TIFF and PNG are 16-bit sRGB; JPEG is 8-bit sRGB. TIFF defaults
to no compression and optionally supports LZW. DNG contains processed 16-bit RGB
in output-referred linear sRGB; TIFF has broader viewer compatibility.

**Export Selected** follows import order; **Export All** queues every import.
During export, **Add Selected** appends independent jobs using the currently
shown format, destination, compression, and framing settings. Duplicate jobs
are allowed and receive collision-safe names. The sidebar marks active and
pending exports. **Cancel** stops at safe processing boundaries; a synchronous
RAW decode or writer call must finish before it can return.

RAW exports decode one file at a time at final quality. The selected file keeps
its last three-pass decode for settings-only re-export and releases it on
selection change. Source files are preserved. Failed outputs are removed and
errors are shown on the Export page.

## Keyboard Shortcuts

| Action | Shortcut |
|---|---|
| Import | Command-O |
| Previous / next scan | Option-Command-Up / Down |
| Fit / 100% preview pixels | Command-0 / Command-1 |
| Zoom in / out | Command-plus / minus |
| Undo / redo | Command-Z / Command-Shift-Z |
| Copy / paste corrections | Option-Command-C / V |
| Export selected / all | Command-E / Command-Shift-E |
