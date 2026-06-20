# Film Scan Converter

A standalone application used for processing RAW film scans from a digital camera into final images  
![image](./docs/images/ed4f2e61-0fa0-404f-bdea-c34ea1925662.png)

## Project Direction

The native Swift/macOS application is the primary product and the only target
for new features and new processing functionality. Its current capabilities,
remaining replacement work, and ordered next steps are tracked in the
[native macOS development status](docs/development/native-macos.md).

The Python/Tkinter application remains available as a maintenance-only legacy
workflow because native dust removal, release packaging, and fixture-tooling
retirement are not complete. Native crop/perspective correction and
TIFF/JPEG/PNG/processed-RGB-DNG export are implemented. See
[Legacy Python Application](docs/legacy-python.md) for the legacy app's limited
role and retirement gates.

## Documentation

The documentation is located in the [/docs](docs/index.md) directory.

Quick Links:

- [Installation](docs/installation.md)
- [How to Use](docs/how-to-use.md)
- [Native macOS development status](docs/development/native-macos.md)
- [Legacy Python application](docs/legacy-python.md)

Developer documentation and contribution guidelines are available in the
[developer guide](docs/development/index.md).

## ART Integration

The legacy Python application can be integrated into [Art Raw Editor](https://artraweditor.github.io). This integration is maintenance-only and is documented in [docs/how-to-add-to-ART.md](docs/how-to-add-to-ART.md).

## Contributing

If you're reading this, thanks for helping me take this project further beyond what I can accomplish on my own. The analog community has long been deprived of a free, intuitive, and standalone film inversion application, and your contribution will help film photography be more accessible to many more people.

Please continue reading in the [contributing](docs/contributing.md) chapter.
