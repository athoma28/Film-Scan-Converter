# Developer Guide

New product work belongs in the native Swift/macOS app. Use
[development status](native-macos.md) for current behavior and evidence and the
[roadmap](../improvements/MacOS-Native-Roadmap.md) for remaining work.

## Build, Test, And Release

- [Building](building.md): Swift toolchain, regression commands, and local launch.
- [Test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md): fixtures, RAW corpus, roll workflow, and
  independent-reader checks.
- [Release runbook](native-release.md): self-contained packaging, signing,
  notarization, and clean-machine validation.
- [Contributing](../contributing.md): source ownership and change requirements.
- [Native package](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/README.md): targets, commands, and contracts.

## Architecture And Performance

- [Still preview architecture](realtime-preview-plan.md): image tiers,
  scheduling, viewport, and preview/export boundaries.
- [X-Trans mosaic binning](xtrans-preview-mosaic-binning.md): why requested
  preview bounds produce discrete pixel sizes.
- [40 MP export benchmark](../performance/40mp-export.md): workload definitions,
  stage timing, deterministic decode evidence, and memory/cancellation checks.
- [Preview analysis benchmark](../performance/preview-analysis.md): bounded CPU
  diagnostics and Darkroom analysis, including current sort-reuse measurements.
- [RAW compatibility benchmark](native-raw-benchmark.md): the frozen
  `rawPyCompatibility` decoder evidence, separate from camera-scan export.

Run the CPU/Metal comparator with normal macOS graphics access:

```sh
swift run -c release --package-path native/FilmScanEngine FilmScanPreviewComparator
```

It must complete 2,725 comparisons with zero render failures and maximum channel
error at most 2/255. It exits unsuccessfully if Metal is unavailable, no
comparisons complete, a render fails, or the tolerance is exceeded. Recorded
results are in the [verification summary](native-macos.md#verification-summary).

## Supporting Workflows

[Density-matrix fitting](density-matrix-calibration.md) and
[reference-curve calibration](reference-negative-calibration.md) document
existing offline tools and profile provenance. Further fitting is parked under
the [research scope](../film-processing-research.md).

The [Python application](../legacy-python.md) remains maintenance-only for
applied dust removal, cross-platform/ART workflows, and fixture tools. Frozen
compatibility fixtures govern shared behavior; new native features use Swift
CPU contracts.
