# Film Scan Converter

Film Scan Converter is a free, open-source macOS application for turning
camera-scanned film negatives and slides into finished images. The current app
is a native Swift/SwiftUI workflow with responsive previews, non-destructive
editing, roll-wide settings, and full-resolution export.

## Current Status

**Film Scan Converter 0.2.0 Beta 1** is available for Apple Silicon Macs running
macOS 14 or later. The native macOS app is the primary product and the only
target for new features.

The beta currently includes:

- Camera RAW, TIFF, PNG, JPEG, and BMP import with fast bounded previews and an
  optional higher-detail demosaiced RAW preview.
- Color-negative, black-and-white-negative, slide, and Original (no-inversion)
  workflows with film-base measurement, inversion, tone and color controls,
  curves, and color wheels.
- Automatic frame detection, straighten, crop, four-corner perspective
  correction, original/corrected comparison, and pan/zoom inspection.
- Per-file settings and session-local undo/redo, presets, copy/paste,
  apply-to-selected/all, import-ordered previous/next, ordered batch export
  with active/pending sidebar status, and full-resolution TIFF, JPEG, PNG, and
  processed-RGB DNG output.

This is an ad-hoc-signed technical beta, not yet an Apple-notarized general
release. Applied dust removal is not yet available; native dust detection is
currently a diagnostic overlay only. See the
[0.2.0 Beta 1 release notes](RELEASE_NOTES.md) and
[native macOS development status](docs/development/native-macos.md) for the
verified release position and known limitations.

Download the newest prerelease from
[GitHub Releases](https://github.com/athoma28/Film-Scan-Converter/releases),
verify the included SHA-256 checksum, unzip it, and move **Film Scan Converter**
to Applications. On first launch, Control-click the app, choose **Open**, then
confirm **Open**. See [Installation](docs/installation.md) for details.

The former Python/Tkinter application remains available as a maintenance-only
legacy workflow, primarily for applied dust removal and existing cross-platform
users. See [Legacy Python Application](docs/legacy-python.md).

## Documentation

The documentation is located in the [/docs](docs/index.md) directory.

Quick Links:

- [Installation](docs/installation.md)
- [How to Use](docs/how-to-use.md)
- [Native macOS development status](docs/development/native-macos.md)
- [Native macOS product roadmap](docs/improvements/MacOS-Native-Roadmap.md)
- [Legacy Python application](docs/legacy-python.md)

Developer documentation and contribution guidelines are available in the
[developer guide](docs/development/index.md).

## ART Integration

The legacy Python application can be integrated into [Art Raw Editor](https://artraweditor.github.io). This integration is maintenance-only and is documented in [docs/how-to-add-to-ART.md](docs/how-to-add-to-ART.md).

## Contributing

If you're reading this, thanks for helping me take this project further beyond what I can accomplish on my own. The analog community has long been deprived of a free, intuitive, and standalone film inversion application, and your contribution will help film photography be more accessible to many more people.

Please continue reading in the [contributing](docs/contributing.md) chapter.
