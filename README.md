# Film Scan Converter

A standalone application used for processing RAW film scans from a digital camera into final images  
![image](./docs/images/ed4f2e61-0fa0-404f-bdea-c34ea1925662.png)

## macOS Beta

The native Swift application is ready for public beta use on Apple Silicon Macs
running macOS 14 or later. Download the newest prerelease from
[GitHub Releases](https://github.com/athoma28/Film-Scan-Converter/releases),
verify the included SHA-256 checksum, unzip it, and move **Film Scan Converter**
to Applications.

The first beta is ad-hoc signed because the project does not yet have an Apple
Developer ID certificate. On first launch, Control-click the app, choose
**Open**, then confirm **Open**. This is a transparent beta limitation, not a
request to disable Gatekeeper. See [Installation](docs/installation.md) and the
[beta release notes](RELEASE_NOTES.md) before using it.

## Project Direction

The native Swift/macOS application is the primary product and the only target
for new features and new processing functionality. Its current capabilities,
evidence, limitations, and release position are tracked in the
[native macOS development status](docs/development/native-macos.md).
The [native product roadmap](docs/improvements/MacOS-Native-Roadmap.md)
separates first-release requirements from optional later work. Current priority
is learning from real beta use while improving the fast, flexible photographer
workflow—image judgment, reversible edits, roll consistency, and trustworthy
output. Stock-look learning and calibration experiments are parked until
explicitly resumed.

The Python/Tkinter application remains available as a maintenance-only legacy
workflow because dust removal remains Python-only and fixture tools still use
legacy modules. Python retirement is not itself a blocker for the first native
release. Native
crop/perspective correction, self-contained app/ZIP assembly, and
TIFF/JPEG/PNG/processed-RGB-DNG export are implemented. See
[Legacy Python Application](docs/legacy-python.md) for the legacy app's limited
role and retirement gates.

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
