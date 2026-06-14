# Development and Contribution

## Active Development

The primary development effort is the native Swift/macOS rewrite. Start with
[Native macOS Development](native-macos.md) for the current step, verified
progress, limitations, and next tasks.

The detailed [macOS native roadmap](../improvements/MacOS-Native-Roadmap.md)
contains the longer-term technical design. It is supporting reference material;
the status page above is authoritative.

The [native RAW decode and quality benchmark](native-raw-benchmark.md) records
the current five-file sample-corpus quality and performance results.

A [comprehensive Swift port evaluation](swift-port-evaluation.md) reviews the
entire native codebase: architecture, code quality, implemented scope, remaining
work, risks, and effort estimates.

## Existing Python Application

The Python application remains the production implementation and the reference
for output equivalence. Its tests must continue to pass while the native engine
is developed. Separate Python and native CI workflows protect both sides of
that contract.

Useful development commands:

```sh
.venv/bin/python -m unittest discover -v
swift test --package-path native/FilmScanEngine
swift build --package-path native/FilmScanEngine --product FilmScanConverterMac
```

See [Building](building.md) for the existing Python packaging notes and
[Contributing](../contributing.md) for contribution guidance.
