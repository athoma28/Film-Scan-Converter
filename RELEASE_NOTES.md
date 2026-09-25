# Release Notes

These notes describe versioned macOS artifacts. See
[development status](docs/development/native-macos.md) for current source
behavior, verification, and remaining limitations.

## Film Scan Converter 0.2.0 Beta 3 — September 25, 2026 (PDT)

Beta 3 packages version 0.2.0, build 3 of the native macOS application for
Apple Silicon Macs running macOS 14 or later. It is an ad-hoc-signed technical
beta and is not Apple-notarized.

- Film Base choices for Color C-41, color cyan-mask, B&W negative, Slide, and
  Original, plus nine factory looks and saved presets based on public controls.
  Applying a look preserves each frame's film base, calibration, and geometry.
- Separate Highlights/Shadows and Whites/Blacks controls, plus independent
  Shadow Floor, Midtone Level, and Highlight Ceiling controls. Existing saved
  edits keep their earlier tone response until the user changes a promoted
  control.
- Faster RAW navigation with bounded retained previews, cached corrected
  images, and sharper interactive adjustment previews followed by exact
  full-source refinement.
- Frame ratios for perspective correction, projected alignment grids, keyboard
  corner nudges, and preserved crop/history behavior across orientation changes.
- Deferred look transfer for scans that have not finished decoding, with
  consistent preview, export, contact-sheet, undo/redo, and relaunch behavior.

Final-source verification recorded 739 native tests with 17 opt-in skips and
zero issues, 4,608 CPU/Metal comparator cases with no render failures, all 24
diagnostic Python tests, and strict Swift formatting. Six full-resolution
photographs passed same-source CPU/Metal checks and reopened 16-bit TIFF checks;
a three-frame Fuji roll export and relaunch workflow also passed. The release
packager validates the app bundle, extracted archive, bundled dependencies and
licenses, signatures, and ZIP checksum.

Known limitations: the beta is not notarized and has not passed independent-Mac
installation review. Independent repeated captures for real Noise/HDR quality
checks remain unavailable. Dust detection is diagnostic only, stack alignment
handles translation only, and DNG export contains processed RGB rather than
untouched sensor RAW. See [Features](docs/features.md) and
[development status](docs/development/native-macos.md) for current details.

## Film Scan Converter 0.2.0 Beta 2 — September 9, 2026

Beta 2 packages version 0.2.0, build 2 of the native macOS application for
Apple Silicon Macs running macOS 14 or later. It is an ad-hoc-signed technical
beta and is not Apple-notarized.

- Develop, Geometry, Calibrate, and Export inspector pages with contextual
  conversion, tone/color, film-base, crop, and output controls.
- Colour-accurate staged RAW previews, parallel Fuji unpack and deterministic
  X-Trans wavefront demosaic, plus selected-file three-pass decode retention
  for settings-only re-export.
- Darkroom film/paper inversion, B&W tone curves with CPU/GPU parity, presets,
  roll-wide look transfer, and import-ordered navigation.
- Original-capture Noise/HDR stacking with bounded memory and temporary disk
  storage, explicit upgrade failures, and one output per enabled stack.
- Shared viewport/overlay coordinates, stable Original comparison and source
  upgrades, truthful full-output dimensions, and dependent manual-crop
  invalidation when upstream geometry changes.
- Undo/Redo preserves the uncropped canvas while Manual Crop or Straighten
  remains open, including when restoring geometry after Reset Corrections.
- Perspective and film-base sampling retain the original scan through
  adjustments, presets, Reset, and Undo/Redo. Original comparison is locked
  until the tool closes and restores the prior comparison view.
- Contact-sheet PDF export for selected or all scans: 12 corrected previews per
  Letter-size page, filenames, import order, and one tile per enabled stack.
  Edits are captured at export start; cancellation, failures, and existing PDFs
  are handled without leaving an incomplete sheet or replacing an earlier one.
- Manual Crop now offers square, common landscape, and portrait aspect ratios.
  Ratios stay fixed while drawing and resizing and are saved per scan with
  Undo/Redo. Switching to Free retains the current crop.
- Bounded CPU preview statistics and faster Darkroom analysis. The beta's
  isolated textured-input benchmark measured 103.34 → 43.83 ms p50; process
  peak increased 13.84 → 16.76 MB. Exact output references remain unchanged.

Strict Swift formatting passed. The full native release suite reported 595
tests (585 passing records and 10 opt-in skips) in 325.206 seconds with normal
macOS graphics access. The legacy Python suite ran 24 tests: 23 passed and one
was skipped. Packaged-app, extracted-archive, dependency, license, signature,
and checksum validation are performed by the release packager. Further local
viewport/manual-crop, duplicate-stack, and independent-reader checks are
recorded in [development status](docs/development/native-macos.md). Detailed
timings and source states are in the
[analysis benchmark](docs/performance/preview-analysis.md).

Remaining validation includes broader photographic and real-roll/stack
judgment, Preview/Photos review on an independent Mac, and notarized distribution.
Native dust detection is diagnostic only. Processed DNG contains RGB output,
not untouched sensor RAW. See [Features](docs/features.md) for the current
source's limitations; they may differ from this beta.

## Earlier Releases

[Film Scan Converter 0.2.0 Beta 2](https://github.com/athoma28/Film-Scan-Converter/releases/tag/v0.2.0-beta.2)
was published September 9, 2026. It is an ad-hoc-signed technical beta for
Apple Silicon Macs running macOS 14 or later and is not Apple-notarized.

[Film Scan Converter 0.2.0 Beta 1](https://github.com/athoma28/Film-Scan-Converter/releases/tag/v0.2.0-beta.1)
was published August 14, 2026 for Apple Silicon Macs on macOS 14 or later.
It is ad-hoc signed and is not Apple-notarized. Its release page preserves the
artifact-specific feature list and verification.

Download the ZIP and matching SHA-256 file from the release page and follow
[Installation](docs/installation.md). Release artifacts identify their own
source commit, version/build, checksums, and validation under the
[release runbook](docs/development/native-release.md).
