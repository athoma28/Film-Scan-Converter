# Film Scan Converter

Film Scan Converter is a free, open-source macOS application for converting
camera-scanned negatives and slides into finished images. The native
Swift/SwiftUI app provides non-destructive editing, staged RAW previews,
roll-wide corrections, and full-resolution export.

## Source And Download

The latest downloadable release is
[0.2.0 Beta 2](https://github.com/athoma28/Film-Scan-Converter/releases/tag/v0.2.0-beta.2),
published September 9, 2026. It is ad-hoc signed, supports Apple Silicon and
macOS 14 or later, and is not Apple-notarized. See
[Installation](docs/installation.md) for the download and source-build paths.

## Current Application

- Camera RAW, TIFF, PNG, JPEG, and BMP import. RAW previews sharpen from a
  colour-accurate draft to an inspect preview and then full-sensor detail.
- Develop, Geometry, Calibrate, and Export inspector pages. Natural, Darkroom,
  Classic, and Bypass negative conversion; tone, color, curves, and color wheels.
- Automatic frame detection, freeform/fixed-ratio crop, straighten, perspective
  correction, and viewport-stable Original comparison with Fit, pan, pinch,
  and 100% viewing.
- Per-file settings and undo/redo, presets, correction copy/paste, selected/all
  look application, and import-ordered scan navigation.
- Opt-in repeated-capture stacks with translation alignment and Noise/HDR modes.
- Sequential TIFF, JPEG, PNG, and processed-RGB DNG export with collision-safe
  names and cancellation. Settings-only re-export of the selected RAW reuses
  its last full-quality decode.
- PDF contact sheets with corrected, labeled previews of selected or all scans,
  including one tile per enabled stack.

Native dust detection displays candidates but does not remove dust. Broader
hands-on photographic and roll/stack validation, Preview/Photos judgment, and
notarized distribution on an independent Mac remain open. See the
[feature inventory](docs/features.md), [current verification](docs/development/native-macos.md),
and [roadmap](docs/improvements/MacOS-Native-Roadmap.md).

## Build And Run

Requires macOS 14 or later, Swift 6, and Homebrew LibRaw:

```sh
brew install libraw
swift run --package-path native/FilmScanEngine FilmScanConverterMac
```

Use `./run-swift.sh` as a convenience launcher. See
[Building](docs/development/building.md) for tests and packaging.

## Documentation And Contributions

Start with [How to Use](docs/how-to-use.md) or the [documentation home](docs/index.md).
Development guidance is in the [developer guide](docs/development/index.md) and
[contribution guide](docs/contributing.md). New product work belongs in the
native app. The [Python application](docs/legacy-python.md) is maintenance-only
and retains applied dust removal, cross-platform use, and [ART integration](docs/how-to-add-to-ART.md).
