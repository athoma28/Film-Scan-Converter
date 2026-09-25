# Contributing

Film Scan Converter should help photographers get consistent, pleasing exports
with clear controls and safe, reversible edits. New features belong in the
native Swift/macOS application. Put specialized controls where they do not
obscure the common workflow.

Read [development status](development/native-macos.md) for implementation and
verification, and the [roadmap](improvements/MacOS-Native-Roadmap.md) for remaining
priorities. Broader stock/capture calibration and ML are parked; the September 18
paired color/control investigation is active under the
[color evaluation runbook](development/color-evaluation.md). Python application
work follows the [maintenance policy](legacy-python.md).

## Useful Contributions

- Fix reproducible crashes, incorrect pixels, data loss, or workflow defects.
- Close a concrete roadmap validation gap through real app/packaged-app checks.
- Improve measured latency or memory with comparable before/after benchmarks
  and unchanged output contracts.
- Preserve legacy compatibility and fixture reproducibility where required.

Discuss substantial new product scope in [Issues](https://github.com/athoma28/Film-Scan-Converter/issues).
For bugs, include the app version/source revision, platform, steps, expected
result, and a shareable sample when image-specific. Use the
[security policy](https://github.com/athoma28/Film-Scan-Converter/blob/main/SECURITY.md) for private vulnerability reports.

## Change Requirements

- Implement user-facing behavior through the app path, with focused regression
  coverage where appropriate. An isolated helper does not establish integration.
- Preserve deterministic Swift CPU processing and frozen fixtures for shared
  legacy behavior. Intentional reference changes require documented evidence;
  do not refresh hashes to hide an optimization regression.
- Keep preview scheduling latest-value-wins and caches bounded. Full-sensor
  previews and compatible corrected rasters survive navigation within the cache
  budget; the selected-file export buffer is dropped on selection change.
  RAW export is sequential. Preserve cancellation, collision safety, and cleanup.
- Keep image, geometry editors, diagnostics, and dimension prediction aligned.
  Test geometry changes at Fit scale as well as image-pixel coordinates.
- Document current behavior and its verification limits. Keep historical data
  only where needed for measurement, compatibility, or profile provenance.
  Update the test guide when commands, opt-in flags, fixtures, or suite names
  change. Record new results in development status with source state, environment,
  pass/skip/failure counts, and unrun checks; keep dated reports as snapshots.
- Write PR descriptions around the final behavior, relevant evidence, and any
  material limitations. Use [Building](development/building.md) and the
  [test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md) for validation commands.

## Style And Checks

Use two-space Swift indentation and the existing actor, `Sendable`, and
cancellation conventions. Document public contracts and non-obvious invariants.
Run strict recursive `swift format lint` over the manifest, Sources, and Tests;
run native tests with normal macOS graphics access. CPU-only sandbox failures
do not establish GPU or AppKit regressions. Keep `git diff --check` clean.

Python maintenance should match surrounding style and avoid unrelated
formatting churn. Run its regression suite when Python behavior or fixtures change.
