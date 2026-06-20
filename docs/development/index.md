# Development and Contribution

## Active Product Development

The native Swift/macOS application is now the primary product and the only
target for new features. Start with
[Native macOS Development](native-macos.md) for the current step, verified
progress, limitations, and next tasks.

The detailed [macOS native roadmap](../improvements/MacOS-Native-Roadmap.md)
contains the longer-term technical design. It is supporting reference material;
the status page above is authoritative. Curves, color wheels, and
TIFF/JPEG/PNG/DNG export are complete with verified GPU-CPU equivalence.

The [film-processing research](../film-processing-research.md) defines the
capture-aware, density-domain inversion direction and its staged implementation
track.

The [native RAW decode and quality benchmark](native-raw-benchmark.md) records
the current five-file sample-corpus quality and performance results.

A [real-time still preview plan](realtime-preview-plan.md) records the completed
interactive-preview work and deferred display-surface/idle-render follow-up.

The `FilmScanPreviewComparator` tool (`swift run FilmScanPreviewComparator`)
supports visual review of GPU and CPU rendering. The current automated
parameter grids perform 2,725 channel comparisons within the documented
2/255 tolerance.

A [comprehensive Swift port evaluation](swift-port-evaluation.md) reviews the
entire native codebase: architecture, code quality, implemented scope, remaining
work, risks, and effort estimates.

## Legacy Python Maintenance

The Python application is maintenance-only. It remains in place for dust
handling, the historical all-in-one batch workflow, and fixture/benchmark tools
that still import it. Native crop/perspective correction and TIFF, JPEG, PNG,
and processed-RGB DNG export are implemented. Shared legacy behavior is preserved by frozen fixtures; new
native-only behavior is governed by deterministic Swift CPU contracts. See
[Legacy Python Application](../legacy-python.md) for retirement gates.

Useful development commands:

```sh
.venv/bin/python -m unittest discover -v
swift test --package-path native/FilmScanEngine
swift build --package-path native/FilmScanEngine --product FilmScanConverterMac
```

See [Building](building.md) for native build commands and legacy Python
packaging notes, and
[Contributing](../contributing.md) for contribution guidance.
