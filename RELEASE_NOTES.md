# Film Scan Converter 0.2.0 Beta 1

This technical beta advances the native macOS application from a capable first
release workflow into a more dependable tool for real camera-scanned film. It
is intended for photographers comfortable testing beta software and reporting
reproducible problems.

## Supported system

- macOS 14 or later
- Apple Silicon (`arm64`) for the downloadable application
- Intel users and developers may build from source with Swift 6 and Homebrew
  LibRaw, but that path is not part of the Beta 1 binary test matrix

## What’s improved since 0.1

- **Session undo and redo.** Correction edits can now be stepped backward and
  forward without changing source files; all editing remains non-destructive.
- **More reliable negative profiles.** Reference calibration now respects frame
  orientation, validates held-out frames, and adds a Shanghai GP3 alternate
  profile for better real-film matching.
- **Faster, leaner full-resolution exports.** The adjusted correction path now
  works in place and in parallel, cutting the measured process peak from 1.984
  GB to 1.017 GB while retaining approved output digests.
- **Deterministic parallel X-Trans RAW processing.** Final-quality three-pass
  Fuji X-Trans demosaic keeps LibRaw’s order-sensitive results while safely
  parallelizing independent row phases. Five eight-worker runs matched every
  approved decode/output digest; warm demosaic fell from 12.72–12.77 seconds
  to 3.38–3.54 seconds on the measured 40 MP fixture.
- **Stronger release and performance evidence.** The 40 MP format matrix,
  ten-file engine and app-path export checks, cancellation check, and packaged
  bundle validation now document both output correctness and bounded memory.

The existing 0.1 workflow remains: camera RAW and standard-image import;
color-negative, black-and-white, slide, and Original (no-inversion) workflows;
film-base measurement; curves and color controls; crop, straighten, and
perspective; presets; roll-wide application; and TIFF, JPEG, PNG, and
processed-RGB DNG export.

## What’s next

Since this beta, development added import-ordered previous/next, active/pending
export sidebar status, parallel Fuji compressed unpack, Darkroom log-density
inversion for cyan/purple-mask stocks, repeated-scan stacking, and
colour-accurate RAW drafts that upgrade the selected file to a ~4000px inspect
preview and a 1-pass full-resolution preview. Export now retains the selected
file’s last full-resolution three-pass decode so a settings-only re-export
does not repeat unpack and demosaic. Remaining first-release work is a
real-roll and representative-image check, then Apple notarization and an
independent-Mac installation check.

## Known limitations

- This beta is ad-hoc signed because the project does not yet have a Developer
  ID signing identity. macOS will not treat it as a notarized application; see
  `docs/installation.md` for the normal Finder Control-click/Open flow.
- Native dust detection currently provides a diagnostic overlay; it does not
  apply dust removal to preview or export.
- DNG output contains processed RGB, not untouched sensor mosaics. TIFF is the
  recommended 16-bit interchange format when an application has limited DNG
  support.
- Full-resolution X-Trans export prioritizes final-quality demosaic over speed.
- The downloadable beta is Apple-Silicon-only.

## Verification

The 0.2 candidate has 456 native regression tests across 32 files, including
the camera-scan byte-identity fixture and the deterministic X-Trans regression
gate. The 2026-08-12 measured export cycle verified 18 format outputs, ten
sequential engine TIFFs, ten queued app exports, and active-decode cancellation;
all test outputs scheduled for cleanup were removed. The unsigned-beta packager
validates dependency closure, architectures, bundled license resources, strict
signature, extracted archive, checksum, and bundled-library hashes.

Publication additionally requires green native and legacy GitHub Actions runs.
Independent-Mac installation remains a disclosed follow-up beta check; see
`docs/development/native-release.md`.

Report bugs at:

<https://github.com/athoma28/Film-Scan-Converter/issues>
