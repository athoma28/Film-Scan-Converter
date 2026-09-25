# Scanning Best Practices

Consistent camera scans make the native app's classification, Auto Frame,
film-base measurement, and roll-wide edits easier to review. For each roll:

1. Use a film holder to hold the film flat and undistorted during scanning.
2. Keep the holder's mask and frame edges simple when possible. Notches and
   cutouts can confuse **Auto Frame**, especially on underexposed images.
   Review its result in **Geometry** and use Straighten Edge, Perspective, or
   Manual Crop where needed.
3. Remove visible dust before capture. The native **Dust Mask** shows candidates
   but does not remove them from exports.
4. Fill the camera frame with the photograph while leaving enough visible film
   edge if you intend to use **Auto Detect Edge** for film-base measurement.
5. Use a high CRI light source, or a high-quality LED display such as a high-end LCD or OLED display, as a backlight. Minimize stray light from external light sources.
6. Expose "to the right" of the histogram, maximizing the exposure, while ensuring that no part of the image is clipped.
7. Use a consistent exposure and orientation across the entire roll of film.
8. Keep a blank film-base reference capture at the same exposure if it helps
   you judge the roll. The current native **Sample Area** tool measures a clear
   film area in the *selected scan*; it does not import the separate blank frame
   as a film-base measurement. **Flat Field** loads a separate calibration image
   and requires a matching aspect ratio.

See [How to Use](how-to-use.md#calibrate) for the current Calibrate workflow.

An example film scan:

![Camera scan of a film frame](./images/7aa530f8-f0b6-4345-bfed-0cb2fa739b9c.png)

An example film-base reference capture:

![Blank film-base reference](./images/667d2393-8ebf-469e-9b2d-888913c7b043.png)
