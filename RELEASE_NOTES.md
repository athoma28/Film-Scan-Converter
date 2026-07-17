# Film Scan Converter 0.1.0 Beta 1

This is the first public beta of the native Swift/SwiftUI Film Scan Converter
for macOS. It is intended for photographers who are comfortable testing beta
software and reporting reproducible problems.

## Supported system

- macOS 14 or later
- Apple Silicon (`arm64`) for the downloadable application
- Intel users and developers may build from source with Swift 6 and Homebrew
  LibRaw, but that path is not part of the Beta 1 binary test matrix

## Highlights

- Camera RAW and standard-image import with bounded, responsive previews
- Color-negative, black-and-white-negative, slide, and crop-only workflows
- Film-base measurement, power-law and density inversion, curves, color wheels,
  protected tone/color controls, crop, straighten, and perspective correction
- Per-file settings, presets, copy/paste, selected/all application, and ordered
  batch export
- TIFF, JPEG, and PNG exports tagged as display-referred sRGB
- Standards-valid processed-RGB DNG export using output-referred linear sRGB
- Self-contained application bundle with LibRaw and its non-system libraries

## Known limitations

- This beta is ad-hoc signed because the project does not yet have a Developer
  ID signing identity. macOS will not treat it as a notarized application; see
  `docs/installation.md` for the normal Finder Control-click/Open flow.
- Undo/redo is not implemented. Edits are non-destructive and source files are
  never modified, but use Reset Corrections or saved presets deliberately.
- Native dust detection currently provides a diagnostic overlay; it does not
  apply dust removal to preview or export.
- DNG output contains processed RGB, not untouched sensor mosaics. TIFF is the
  recommended 16-bit interchange format when an application has limited DNG
  support.
- Full-resolution X-Trans export prioritizes final-quality demosaic over speed.
- The downloadable beta is Apple-Silicon-only.

## Verification

The 2026-07-17 local candidate passed all 395 native regression tests with
normal Metal access and all 24 legacy Python tests; opt-in performance tests
remained intentionally skipped. The unsigned-beta packager passed dependency,
architecture, license-resource, strict signature, extracted-archive, checksum,
and bundled-library hash validation. The packaged app also launched through
macOS Launch Services.

Publication additionally requires green native and legacy GitHub Actions runs.
Independent-Mac installation remains a disclosed follow-up beta check; see
`docs/development/native-release.md`.

Report bugs at:

<https://github.com/athoma28/Film-Scan-Converter/issues>
