# How To Use

This guide describes the current native application, including
[0.2.0 Beta 3](https://github.com/athoma28/Film-Scan-Converter/releases/tag/v0.2.0-beta.3).
See [Installation](installation.md) for
download and source-build paths. Python instructions are in
[Legacy Usage](legacy-usage.md).

## Import And Inspect

Open files with Command-O or drag RAW, TIFF, PNG, JPEG, or BMP scans into the
window. Choose a scan in the Scans sidebar. Command-click or Shift-click selects
multiple files; Previous/Next Scan moves through sidebar order and fits the new
selection.

The **Move selected scan up/down** toolbar
buttons move the primary scan one row while preserving selection. Reordering is
session-local and unavailable during export. Changing capture order within a
stack disables that stack and restores the selected original; enable the new
proposal explicitly if desired. Navigation and newly queued exports follow the
resulting sidebar order.

Camera RAW first displays a colour-accurate draft, then sharpens to an inspect
preview and full-sensor detail. You can edit while it loads. When available,
**Load RAW Preview** requests full-sensor detail directly and cancels an
in-progress inspect decode. A loading bar marks the first draft; a warning
identifies an embedded camera JPEG if RAW colour is unavailable.

Completed full-resolution previews stay in memory as you switch between scans.
The app also prepares nearby images in the background: sharp previews first,
then full detail for up to two neighbours. The preview cache uses up to about
2 GB on a 16 GB Mac or 3 GB on a 24 GB Mac, and releases background images if
macOS reports memory pressure. Returning to a cached scan with unchanged
corrections reuses its finished display image too.

After full-sensor detail arrives, a supported adjustment gesture at whole-image
zoom can temporarily use a sharp 2048px source while keeping the same canvas
size. This can apply to GPU and CPU preview processing. At closer zoom, GPU
previews render the visible region from the full source, while CPU fallbacks
process the full source. Releasing the control replaces
the temporary preview with the exact full-source result. Original comparison
does not use the gesture proxy.

Pan with a trackpad or mouse wheel, pinch to zoom, or use Fit and the zoom
buttons. Once the corrected preview is ready, panning and zooming reuse its
pixels without rebuilding the correction. **100% Preview Pixels** means one current-preview pixel per view point;
it corresponds to sensor pixels after the full-resolution upgrade. **Original**
compares the uncorrected image with matching geometry, pan, and magnification.
Perspective and film-base editors temporarily reveal the oriented source.

The inspector header reports **Full output** dimensions, including geometry and
export framing, rather than the current preview size.

## Develop

**Film Base** chooses Color C-41, color cyan-mask, B&W negative, Slide, or
Original. New scans are classified automatically and receive the first
recommended factory look: Clean Invert for color or Slide, B&W Print for B&W.
You can override either choice. Changing film base switches the invert defaults
only. It does not apply a new look, and looks never change film base.

**Presets** has a compact menu of recommended, other factory, and saved looks,
keeping the adjustment sliders close at hand. Choose a name to assign its public
slider, curve, and wheel values. The sliders jump to
those values. If you then move any of those controls, the header shows
**Custom**. Command-Z undoes the apply. **Save current as preset** stores the
same snapshot under a name you choose. An existing name shows **Replace** before
saving; a failed save keeps the name available to retry. Use **Manage Saved
Presets** to remove a saved look.

The first save or deletion that upgrades an older preset library also keeps a
`CorrectionPresets-v1-<id>.json` backup beside the library. It retains the original
settings, including legacy inversion and calibration fields.

**Reset Adjustments** clears the Develop tone, color, curves, and wheels while
keeping your film base, calibration, crop, and orientation. Command-Z restores
the adjustments. Original film base uses framing and export only; choose a
negative or Slide base to enable Develop controls.
The Corrections menu also offers **Reset Image and Framing** when you want to
clear the film-base choice and geometry along with the adjustments.

| Factory look | Starting direction |
|---|---|
| Clean Invert | Straight invert with modest cast cleanup. |
| Soft People | Gentler contrast, quieter color, a little warmth. |
| Punchy Print | Stronger midtones and a modest S-curve. |
| Warm | Golden warmth and richer color. |
| Cool | Cooler color and softer bright lights. |
| Foliage | Pull copper greens toward olive. Lower foliage recovery if wood or skin shifts. |
| Night Lift | Open a dark frame and keep lamp warmth. |
| B&W Print | Monochrome with print contrast. |
| B&W Soft | Open, gentle monochrome. |

These are creative starting points, not measured stock or paper simulations.
Color negatives invert with a generic C-41 or cyan-mask density-print path and
a neutral print response. There is no separate conversion mode, film stock, or
paper picker.

**Tone & Light** and **Color & Balance** stay visible. Slider zero is the global
neutral, so applying a look is visible on the controls. Color negatives also
show foliage recovery, cast cleanup, and color separation. Double-click a
slider to restore zero. B&W uses an overall Tone curve; color-channel curves
are for color film types.

Highlights and Shadows adjust broad bright and dark regions. Whites and Blacks
focus closer to the ends of the tonal range while retaining the black and white
points. In **Color Grading Wheels**, the three small sliders below the wheels
serve a different purpose: **Shadow Floor** raises the black output point for
soft blacks, **Midtone Level** shifts the center, and **Highlight Ceiling**
lowers the white output point for softer highlights. Their zero positions leave
the image unchanged. A first edit to one of these controls or to
Highlights/Shadows/Whites/Blacks updates an older photographic-tone edit to the
new response; Undo restores the prior version and appearance. Version 1 edits
still require **Update Tone Controls** first. Built-in looks retain their saved
starting appearance until you edit one of those controls.

Copy/paste transfers the current slider snapshot without changing the
destination's geometry, film base, or calibration. Old correction documents are
migrated to public adjustments; their inversion/calibration settings are not
transferred. The ellipsis menu contains **Apply Look
to Selected** and **Apply Settings to All Open Files**.

Edits save automatically in the background for the source path. Finishing a
gesture requests a save, and normal application quit waits for pending saves.
Command-Z and Command-Shift-Z undo/redo per file; each continuous slider,
curve, wheel, or perspective gesture forms one step. Relaunch restores saved
settings and starts fresh undo history.


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

While Manual Crop is open, **Crop Ratio** offers Free, 1:1, 3:2, 4:3, 5:4,
16:9, and the corresponding portrait ratios. Choosing a fixed ratio fits a
centered rectangle inside the current crop (or the full canvas if no crop is
set). Drawing and all eight handles keep that ratio; dragging inside moves the
box without resizing it. **Free** unlocks the existing box without changing it.
The ratio is saved per scan and restored with Undo/Redo. Clearing the crop
keeps the chosen ratio for the next drag. Output edges round outward to whole
pixels, so very small crops can differ slightly from the nominal ratio.

Undo/Redo keeps an open Manual Crop or Straighten editor on the full canvas,
so you can restore an edit and continue adjusting it without leaving the tool.
Perspective and Film Base Sample Area keep the oriented original scan visible
through adjustments, presets, Reset, and Undo/Redo. Original comparison is
locked while either tool is open; finishing restores the prior comparison view.

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

**Export Selected** follows sidebar order; **Export All** queues every import.
During export, **Add Selected** appends independent jobs using the currently
shown format, destination, compression, and framing settings. Duplicate jobs
are allowed and receive collision-safe names. The sidebar marks active and
pending exports. **Cancel** stops at safe processing boundaries. RAW decoding
observes cancellation at native checkpoints; synchronous ImageIO/writer calls
must return before the queue can finish cancelling.

RAW exports decode one file at a time at final quality. The selected file keeps
its last three-pass decode for settings-only re-export and releases it on
selection change. Source files are preserved. Failed outputs are removed and
errors are shown on the Export page.

### Contact Sheets

Choose a Destination folder, then use **Contact Sheet → Save Selected PDF** or
**Save All PDF** on the Export page. The File menu also offers both actions.
The PDF contains 12 scans per Letter-size page, in sidebar order, with filenames
and current crops/corrections. Each enabled stack appears once under the first
capture's name. **Open Contact Sheet** opens the completed PDF.

The sheet captures edits when export starts, so later adjustments do not change
its remaining tiles. It uses review-size previews and omits export borders and
aspect padding. Existing PDFs receive numbered alternatives such as
`Contact Sheet-2.pdf`. **Cancel** or a failed scan removes the unfinished sheet;
the PDF appears only after every scan succeeds.

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
