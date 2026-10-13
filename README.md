# Film Scan Converter

Film Scan Converter is a free, open-source macOS app for turning camera-scanned
film negatives and slides into finished photographs. The current app is built
in Swift and SwiftUI, with non-destructive editing, RAW previews, and
full-resolution export.

## Why I built it

I like using Adobe Camera Raw to edit RAW files, but film-negative inversion
is cumbersome there. When I started looking for open-source alternatives, the
ones I tried were far slower at loading, editing, and exporting my scans. I
wanted a film workflow that felt more responsive.

This project grew out of
[kaimonmok's original Python Film Scan Converter](https://github.com/kaimonmok/Film-Scan-Converter).
It has since become a native Mac app, with much of my time going into faster RAW
loading, preview rendering, switching between scans, and export. The Python
version remains in the repository for legacy workflows and compatibility tools;
new product work happens in the native app.

Plenty of people at the intersection of software and film photography have
built something similar. This is my version, and it reflects my own scans and editing
preferences. I've put a significant amount of work into speed and UI
responsiveness, and I'd still call it about halfway to what I would consider a
really high-quality project.

## What it does

- Opens camera RAW files and TIFF, PNG, JPEG, and BMP images, with progressively
  sharper RAW previews and cached images for browsing a roll. Camera Raw's loading process is still faster and that points to needing to rewrite the raw processing engine from scratch before we get that fast.
- Inverts color and black-and-white negatives, and supports slides. Factory
  looks and saved presets work through editable sliders, curves, and color wheels.
- Provides exposure, tone, and color adjustments, crop, straighten, perspective
  correction, and optional dust detection and healing.
- Saves per-file edits, supports undo/redo, restores open scans, and copies
  selected adjustment groups across a roll.
- Exports full-resolution TIFF, JPEG, PNG, and processed-RGB DNG, plus PDF
  contact sheets.

See [Features](docs/features.md) for the full inventory and limitations, or
[How to Use](docs/how-to-use.md) for the editing workflow.

## Color processing and upstream work

I drew on color-processing workflows from other open-source projects and built
my own presets around results that worked well for me:

- [NegPy](https://github.com/marcinz606/NegPy): density-based negative inversion,
  dye unmixing, cast removal, and print-response modeling.
- [RawTherapee](https://github.com/RawTherapee/RawTherapee): film-negative inversion
  and display-rendering workflows, plus adapted RCD demosaicing.
- [LibRaw](https://www.libraw.org/): camera RAW decoding and the foundation of
  the X-Trans demosaicing path.

The factory looks are personal creative starting points, not measured film-stock
calibrations. More detail about adapted code and dependencies is in
[Third-Party Notices](THIRD_PARTY_NOTICES.md). The project is licensed under
[GPLv3](LICENSE).

## Testing and limitations

My hands-on photographic testing has been limited to my own negatives
photographed with a Fujifilm X-T5, on my own Mac with 48 GB of unified memory.
Performance, memory use, RAW handling, and color results are very likely to
differ with other machines, cameras, and capture setups. The presets reflect
that narrow experience too.

This is still a beta. Broader camera coverage, independent-Mac testing, and
photographic review of dust repair and stacking remain unfinished. The
[development status](docs/development/native-macos.md) records what has been
checked, and the [roadmap](docs/improvements/MacOS-Native-Roadmap.md) tracks
remaining work.

## Download or build

Find downloads on the
[releases page](https://github.com/athoma28/Film-Scan-Converter/releases).
The documented beta targets Apple Silicon Macs running macOS 14 or later and
is ad-hoc signed, not Apple-notarized. Follow [Installation](docs/installation.md)
for setup details.

To run from source, install Swift 6 through Xcode or Command Line Tools and
Homebrew, then run these commands from the repository root:

```sh
brew install libraw pkg-config
swift run --package-path native/FilmScanEngine FilmScanConverterMac
```

Start with the [developer guide](docs/development/index.md) and
[native package documentation](native/README.md) for development. The
[documentation home](docs/index.md) also links the user guides and the
[legacy Python workflow](docs/legacy-python.md).

## Make it your own

I hope the work I've done to find speedups is useful to others in this community.
As software gets easier to make, I don't expect this to become a widely used
project, and that's fine. If it helps you build a tool that suits your own
photography, I'd be happy with that.

I encourage you to fork it and make
it your own. Fixes and useful findings are welcome too; see
[Contributing](docs/contributing.md).

Special thanks to [kaimonmok](https://github.com/kaimonmok) for getting the ball
rolling with the original Python version.
