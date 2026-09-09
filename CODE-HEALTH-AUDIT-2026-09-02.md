# Native Correctness Regression Contracts

The September 2 audit's reported defects are resolved. This retained reference
summarizes the resulting contracts rather than listing fixed bugs as open work.
Current evidence and limitations live in
[development status](docs/development/native-macos.md).

- Overall B&W tone curves apply consistently in Natural, Classic, and basic
  inversion on CPU/GPU. Saved color-channel adjustments cannot tint monochrome.
- Full-resolution preview/export stack original captures with independent
  statistics, alignment, and exposure weights. Temporary row-band storage is
  cleaned on success, failure, and cancellation.
- Manual crop can be cleared while retaining earlier frame geometry. Upstream
  geometry changes invalidate dependent canvas crops.
- Crop/film-base failures remain visible. A failed final stack tier preserves
  a usable preview and status; retry can recover.
- Dimension labels apply each geometry stage once. Specialized controls respect
  film-type capabilities, and stack controls retain accessibility labels.

Regression tests cover multi-capture outlier rejection, translated HDR edges,
monochrome stacks, cleanup, upgrade/retry, independent crop reset, dimensions,
median selection, and B&W curve parity. Source-level defect reproductions and
resolved implementation details remain in Git history.
