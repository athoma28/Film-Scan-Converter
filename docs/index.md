# Film Scan Converter

Film Scan Converter converts camera-scanned film negatives and slides in a
native macOS application. The feature and usage guides describe the current
application, including published
[0.2.0 Beta 3](https://github.com/athoma28/Film-Scan-Converter/releases/tag/v0.2.0-beta.3).
See [Installation](installation.md) for download and source-build instructions.

## Use The Application

- [Features](features.md): available tools and limitations.
- [How to Use](how-to-use.md): Develop, Geometry, Calibrate, and Export workflow.
- [Scanning Best Practices](best-practices.md): prepare consistent input scans.

## Develop And Verify

- [Development status](development/native-macos.md): current evidence and gaps.
- [Product roadmap](improvements/MacOS-Native-Roadmap.md): remaining priorities.
- [Building](development/building.md) and [release runbook](development/native-release.md).
- [Developer guide](development/index.md): architecture, tests, and benchmarks.
- [Test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md): maintained regression commands, private-corpus
  requirements, and opt-in checks; dated measurements are evidence for their
  recorded source state rather than the latest build.
- [Color evaluation runbook](development/color-evaluation.md): reproduce paired
  reference studies, skin RGB measurements, and film-preset comparisons.

The native app is the only target for new features. The
[legacy Python application](legacy-python.md) retains applied dust removal and
cross-platform/ART workflows. Broader stock/capture calibration research is parked;
[research documentation](film-processing-research.md) describes its boundaries.
The September 18 paired color/control investigation is documented in the color
evaluation runbook above.
