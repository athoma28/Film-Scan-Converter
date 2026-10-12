# Working in Film Scan Converter

New product work belongs in the native Swift/macOS app. Start with
[the developer guide](docs/development/index.md) and
[native contracts](native/README.md). Preserve unrelated working-tree changes.

## Color, film presets, and reference comparisons

Read [the color evaluation runbook](docs/development/color-evaluation.md) before
fitting presets, comparing Camera Raw references, changing color defaults, or
interpreting the diagnostic galleries. It contains setup, ordered commands,
artifact schemas, measurement rules, and the procedure for adding new frames.

- Use `native/diagnostics/color-study.py` for preflight and reproducible runs.
  Inspect existing reports first; choose a fresh output after code/input changes.
- Render FSC candidates through the production Swift engine. Keep private scans
  and generated images in ignored `sample-raw/` and `dist/`.
- Preserve the user-preferred looks in
  `docs/development/color-preference-checkpoints.json`. A lower Camera Raw error
  does not override the user's preference. Verify fresh renders after engine changes.
- Separate per-frame reference fits, conditional transfer of a correction, and
  validation of an entire profile on unseen photographs. Report failures and
  exclusions as well as improvements; use training data for recipe selection.
- Inspect registration, masks, individual skin regions, and non-skin colors.
  Validate corrections with the real app parser and verify full-resolution output
  before making export claims. CPU studies alone do not establish Metal parity.

The September 18 paired color/control study is active work, distinct from the
older parked density-matrix calibration project. Historical study notes describe
evidence, not blanket authorization to replace shipped defaults.
