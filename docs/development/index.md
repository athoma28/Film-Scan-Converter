# Development and Contribution

## Active Product Development

The native Swift/macOS application is now the primary product and the only
target for new features. Start with
[Native macOS Development Status](native-macos.md) for verified behavior,
limitations, release position, and the bounded current work.

The [native product roadmap](../improvements/MacOS-Native-Roadmap.md) is the
single ordered plan. It separates work required before the first public release
from evidence-driven post-release candidates and explicitly unplanned ideas.

The [film-processing research](../film-processing-research.md) and
[density-matrix calibration contract](density-matrix-calibration.md) are parked
reference material. They preserve the capture-aware color-science work already
done, but corpus preparation, named-stock fitting, residual LUTs, and ML work
are not active priorities unless the project owner explicitly resumes them.

The [native RAW decode and quality benchmark](native-raw-benchmark.md) records
the eight-file `rawPyCompatibility` decode snapshot. The local regression
manifest uses a five-file half-resolution subset plus one full-resolution
sample; neither should be confused with the app's camera-scan export profile.

A [real-time still preview outcome](realtime-preview-plan.md) records the
historical interactive design, the retired idle-replacement proposal, and
deferred display-surface options. It does not set current priority.

The `FilmScanPreviewComparator` tool
(`swift run --package-path native/FilmScanEngine FilmScanPreviewComparator`)
supports visual review of GPU and CPU rendering. The current automated
parameter grids perform 2,725 channel comparisons within the documented 2/255
tolerance.

A [Swift port evaluation](swift-port-evaluation.md) records an earlier
architecture review. Treat it as historical evidence rather than a checklist.

## Legacy Python Maintenance

The Python application is maintenance-only. It remains in place for dust
handling, the historical all-in-one batch workflow, and fixture/benchmark tools
that still import it. Python retirement is not a blocker for the first native
release when the remaining Python-only workflows are documented honestly.
Shared legacy behavior is preserved by frozen fixtures; new native-only
behavior is governed by deterministic Swift CPU contracts. See
[Legacy Python Application](../legacy-python.md) for retirement gates.

Useful development commands:

```sh
.venv/bin/python -m unittest discover -v
swift test --package-path native/FilmScanEngine --no-parallel
swift build --package-path native/FilmScanEngine --product FilmScanConverterMac
```

See [Building](building.md) for native build commands and legacy Python
packaging notes, and
[Contributing](../contributing.md) for contribution guidance.
