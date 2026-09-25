# Film Scan Converter

Film Scan Converter is a free, open-source macOS application for converting
camera-scanned negatives and slides into finished images. The native
Swift/SwiftUI app provides non-destructive editing, staged RAW previews,
roll-wide corrections, and full-resolution export.

## Download And Source Status

The current downloadable build is
[0.2.0 Beta 3](https://github.com/athoma28/Film-Scan-Converter/releases/tag/v0.2.0-beta.3),
for Apple Silicon Macs running macOS 14 or later. It is ad-hoc signed and is not
Apple-notarized. See [Installation](docs/installation.md) for the download and
source-build paths.

## Current Application

- Import camera RAW, TIFF, PNG, JPEG, and BMP. RAW previews progress from a
  demosaiced draft through an inspect preview to full-sensor detail; completed
  previews can be reused when switching scans.
- Develop with Film Base choices of Color C-41, color cyan-mask, B&W negative,
  Slide, and Original. Nine factory looks and saved presets set visible sliders,
  curves, and color wheels without changing film base, calibration, or framing.
  Factory looks are creative starting points, not measured film-stock profiles.
- Adjust exposure and color with separate broad Highlights/Shadows and focused
  Whites/Blacks controls, plus Shadow Floor, Midtone Level, and Highlight Ceiling
  under the grading wheels. Color negatives also have cast cleanup, color
  separation, and foliage recovery controls. Older saved edits retain their
  previous tone response until updated through the app.
- Edit geometry with Auto Frame, freeform or fixed-ratio crop, straighten, and
  four-corner perspective. Fit, pan, pinch, 100% preview pixels, and Original
  comparison preserve the viewed region where appropriate.
- Save per-file edits with undo/redo. Copy corrections or apply a look to selected
  or all scans while keeping each destination's film base, calibration, and
  geometry. Browse scans in sidebar order and optionally reorder them during
  the session.
- Combine opt-in repeated captures using translation alignment and Noise or HDR
  stacking. Calibrate with film-base sampling, flat fields, and optional density
  and dye controls. A live camera preview is available for devices macOS exposes.
- Export sequentially to TIFF, JPEG, PNG, or processed-RGB DNG with collision-safe
  names and cancellation. A selected RAW can reuse its last full-quality decode
  for a settings-only re-export. Export corrected, labeled PDF contact sheets for
  selected or all scans, with one tile per enabled stack.

Native dust detection displays candidates but does not remove them. Stack
alignment handles translation only, and DNG export contains processed RGB rather
than sensor RAW. Broader photographic and roll/stack validation, output review
on an independent Mac, and notarized distribution remain open. See the
[feature inventory](docs/features.md), [current verification](docs/development/native-macos.md),
and [roadmap](docs/improvements/MacOS-Native-Roadmap.md).

## Build And Run

Source builds require macOS 14 or later, Swift 6 through Xcode or Command Line
Tools, and Homebrew LibRaw with `pkg-config`. From the repository root:

```sh
brew install libraw pkg-config
swift run --package-path native/FilmScanEngine FilmScanConverterMac
```

`./run-swift.sh` is a convenience launcher. See
[Building](docs/development/building.md) for tests and local app packaging.

## Documentation And Contributions

Start with [How to Use](docs/how-to-use.md) or the [documentation home](docs/index.md).
Development guidance is in the [developer guide](docs/development/index.md) and
[contribution guide](docs/contributing.md). New product work belongs in the
native app. The [Python application](docs/legacy-python.md) is maintenance-only
and retains applied dust removal, cross-platform use, and [ART integration](docs/how-to-add-to-ART.md).

For color, film-preset, and Camera Raw comparisons, use the
[color evaluation runbook](docs/development/color-evaluation.md) for preflight,
production renders, measurements, and the current compatibility limits of the
historical studies.
