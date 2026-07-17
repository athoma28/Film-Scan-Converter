
# How to Use It

## Native Swift/macOS Application

The native application is the primary product. It provides:

- Drag-and-drop import of RAW and standard image files.
- Per-file correction controls: film mode (color negative, B&W negative, slide),
  film-negative inversion using RawTherapee's exponent model and presets,
  orientation, white balance, exposure, shadows, highlights, saturation,
  RGB tone curves, highlight/midtone/shadow color wheels.
- Camera-scan RAW processing with ISO-tier noise/detail filtering. Browsing
  starts with the camera's embedded preview, bounded to a 1000px long edge.
  **Load RAW Preview** explicitly replaces it with a demosaiced preview up to
  2400px, recalibrated from RAW pixels for unusual film bases. Export still
  re-decodes RAW files at full resolution, using RCD for Bayer data or
  three-pass Markesteijn interpolation for X-Trans.
- Interactive GPU-accelerated preview that updates during slider drags, with
  native pan/pinch navigation plus Fit, step-zoom, and 100% commands.
- Export to named-sRGB TIFF (16-bit, optional LZW), JPEG (8-bit, configurable
  quality), and PNG (16-bit lossless), plus processed 16-bit RGB DNG encoded as
  output-referred linear sRGB. Prefer TIFF when another application has limited
  processed-DNG support.
- Individual, import-ordered multi-selection, and memory-bounded Export All
  workflows, plus duplicate-friendly append-selected jobs during an active
  sequential export.

### Workflow

1. Launch the app with `swift run --package-path native/FilmScanEngine FilmScanConverterMac`
   or `./run-swift.sh`.
2. Drag and drop supported RAW or image files onto the app window.
   A bounded preview appears first for large files, while the inspector header
   reports full-resolution output dimensions from file metadata. That readout
   updates after crop, rotation, and straightening; it does not report the
   preview proxy size. For a camera RAW, choose **Load RAW Preview** in the
   toolbar when the embedded preview's color is untrustworthy or more detail is
   useful. Full-resolution RAW decoding still happens independently during
   export. The badge over the preview names the current source and its displayed
   pixel dimensions, so an embedded RAW thumbnail is not mistaken for export
   evidence.
   Use a two-finger trackpad gesture or mouse wheel to pan, pinch to zoom, or use
   the toolbar's minus/plus buttons and Fit/100% menu. Command-0 fits the image,
   Command-1 shows one preview pixel per point, and Command-plus/minus changes
   magnification in steps.
3. New files are automatically classified as color negative, B&W negative, or
   slide. Review and adjust the film mode and film negative preset as needed.
4. Adjust corrections in the inspector panel: orientation, white balance,
   semantic exposure/brightness/contrast/highlights/shadows, temperature/tint,
   saturation, vibrance, curves, and color wheels.
   The preview updates in real time as you drag sliders.
   Tone and film-profile sliders provide finer movement around their neutral
   values while retaining their full range. Curves start from an identity line,
   render as a smooth shape-preserving curve, and keep adjacent points ordered
   while dragging.
   Grade-page clipping statistics are available from the first displayed render.
   Corrections are saved automatically for that source file and restored the
   next time the same path is imported.
5. For a color negative whose dye records do not separate cleanly, open
   **Film Setup > Dye crossover**. Each slider says which source channel is
   being mixed into a destination channel. Use a small negative value to
   subtract an unwanted crossover cast, or a positive value to add that source
   channel. The matrix operates before tone and grading and preserves neutral
   gray, so it can correct relationships that Temperature/Tint or the three
   exponent controls cannot. **Reset Dye Crossover** returns to the exact
   neutral matrix.
6. Use the Settings section to copy or paste a look, or save, apply, and delete
   named presets. After applying a named preset or **Kodachrome-like Auto**, use
   its **Remove** action to restore the adjustments from immediately before the
   preset without resetting crop or orientation. Transferred looks keep the
   destination scan's rotation, crop, and measured film-base state.
7. In **Processing Profiles**, a saved Film-Stock Profile captures the current
   negative exponents, dye-crossover matrix, density response, and display
   rendering settings. These are user-created priors; the app does not yet
   claim calibrated built-in profiles for individual stocks.
8. In Film Base, optionally load a matching flat field and measure a clear,
   unexposed film edge automatically or by dragging over it. This enables the
   measured density pipeline for negative conversion.
9. In Film Frame, choose **Straighten**, click two points along a horizon or
   vertical edge, and the app rotates the canvas to make that guide horizontal
   or vertical. Choose **Crop** and drag a box over the area to keep; the preview
   switches to the cropped canvas immediately. Choose **Crop** again to reveal
   the whole straightened canvas and replace the crop, or use **Reset Crop** to
   remove it. Tune the
   dark/light thresholds and choose **Detect Frame** for automatic frame
   detection, or use **Adjust Perspective** for a four-corner correction. Each
   corner is a targeting reticle; while dragging, its loupe magnifies a
   100×100-pixel preview area around the exact designation point. Parallel-edge
   assist softly snaps likely trapezoids; hold Option while dragging for an
   unconstrained quadrilateral. Perspective warps the full canvas and remains
   separate from the later rectangular **Crop**, so either can be reset without
   clearing the other.
   Preview, the full-resolution dimension readout, and export use the same
   stored geometry.
10. Use the original/corrected comparison toggle to evaluate your adjustments.
    The current pan position and magnification stay fixed across the comparison.
11. Use **Detect Dust** to inspect a non-destructive candidate overlay. Clear it
   when finished; the overlay is diagnostic and is not exported.
12. Set export options (format, frame, aspect ratio) and choose a destination
   folder.
13. Command-click or Shift-click sidebar rows to select a subset, then click
    **Export Selected**; use **Export All** for every imported file. While an
    export is running, **Add Selected** appends another independent job for each
    selected file. Duplicate jobs are allowed, and each addition snapshots the
    format, destination, JPEG quality, TIFF compression, frame, and aspect-ratio
    settings currently shown. Collision-safe suffixes keep every requested
    copy. Standard images retain source resolution; RAW files are re-decoded at
    full resolution one at a time so batch memory remains bounded.

The native app can display dust-mask candidates, but it does not apply dust
removal. Applied dust removal is an evidence-driven post-release candidate, not
an active implementation step. Use the legacy Python application when automatic
removal is required. See
[Native macOS Development](development/native-macos.md) for the current status.

## Legacy Python Application (Maintenance Only)

### Batch Processing

This application enables you to import multiple RAW scans (most RAW image formats supported), and process them all simultaneously. Each photo's settings can either be synced with global settings, or have settings independent from all the other photos. This is useful when all the photos are scanned in a consistent manner, or you want to dial in the same "look" for multiple photos.

A potential workflow is as follows:

1. Import RAW scans from the same batch and film stock. By default, all photos are synced with global settings.
2. Set the film type (i.e. B&W, Colour, Slide).
3. Set the dark and light threshold so that most photos are cropped properly.
4. If the entire roll has been scanned on the reverse side, the image can be flipped.
5. If applicable, set the colour of the film base.
6. Go through each photo to check that it has been cropped/inverted properly. You can use the arrow keys to cycle through each photo.
7. If an individual photo needs adjustment, uncheck "Sync with Global Settings", then apply the adjustment.
8. Set the export settings, then click "Export All Photos".

### Automatic Cropping

By setting the appropriate dark and light threshold values, the application can automatically find the optimal crop around a photo, even if it is off-center or misaligned. The dark and light threshold values define the minimum and maximum brightness levels of the region of the RAW scan to highlight for retention. An appropriately thresholded image highlights most if not the entirety of the desired image, and excludes the mask and/or the film base. In the "Threshold" view, it should look like a white box surrounded by a black border, as shown below:  
![image](./images/4a768370-e47c-48a8-b76f-8cd934c5d924.png)

You can verify that the application has detected the photo properly using the "Contours" view. The final crop of the photo is shown as a green rectangle, as shown below.  
![image](./images/fd3e44ec-31f6-4054-8ad6-28ee4ad2ae37.png)

If the mask has fuzzy edges, this may show up near the borders of the final image. You can either increase the Border Crop, or fine tune the light and dark threshold values to try to crop it out.

### Colour Correction

By default, each colour channel will be equalized such that the darkest point is pure black and the lightest point is pure white. This produces pleasing colours under most circumstances; however, there may be instances where this algorithm is thrown off by the scanning method or by the particular photo itself. If the colours look wrong in the preview, check the following:

- Is the photo cropped properly? If the final crop contains parts of the film holder or the backlight, the photo may be colour balanced against objects apart from of the photo itself.
- If shadows are the wrong colour, the film base colour is likely incorrect and will need to be manually set. This can be done by one of three ways:
  1. Pick the film base colour from the RAW scan.
  2. Set the RGB value manually.
  3. Import the blank scan of the film base from the same roll.
- If the white balance is wrong, it can be corrected by manually adjusting the temperature and tint values, or by using the white balance picker and clicking on any neutral gray portion of the image.
- If sprocket holes are desired in the final image, they will need to be masked out for the equalization calculation. This can be done by going to Edit -> Advanced Settings -> EQ Ignore Borders %, and increasing the height parameter until the sprocket holes are masked. For 35mm film, a value of 15% usually works. To visualize this masking, it is displayed in the "Contours" view as a red border within the cropped region, as shown below:  
![image](./images/41ef16e7-def5-4a36-9d6d-d7c685c5b1ab.png)

### Command Line Variables
There are 3 command line variables that can be passed in when opening Film Scan Converter, these are:
- Directory: `-d path/to/folder` this will open all compatible files in the given folder on open.  
  Example use: `python "Film Scan Converter.pyw" -d /home/user/Pictures/scans`

- Output Directory: `-o path/to/folder` this will set the output directory to the passed in path  
  Example use: `python "Film Scan Converter.pyw" -o /home/user/Pictures/scans/output`

- Files: `-f path/to/file.tiff` this will open one or multiple files on open, files are separated with a comma (`,`).  
  Example use: `python "Film Scan Converter.pyw" -f "/home/user/Pictures/scans/scan_1.tiff, /home/user/Pictures/scans/scan_2.tiff"`

Multiple variables can be passed at once, so `python "Film Scan Converter.pyw" -d /home/user/Pictures/scans -o /home/user/Pictures/scans/output` is a valid set of options.
