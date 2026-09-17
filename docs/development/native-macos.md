# Native macOS Development Status

This page owns current implementation status, verification, and limitations.
[Features](../features.md) describes the user tools; the
[roadmap](../improvements/MacOS-Native-Roadmap.md) owns priority.

**Latest complete native suite: September 14, 2026.** Local RAW tests depend
on the untracked `sample-raw/` corpus; CI cannot reproduce those cases without it.

## Release Position

The native Swift/SwiftUI app is the primary product. The latest published
binary is [0.2.0 Beta 2](https://github.com/athoma28/Film-Scan-Converter/releases/tag/v0.2.0-beta.2)
(September 9, 2026), an ad-hoc-signed Apple Silicon build for macOS 14 or
later. Later source commits may contain changes beyond that binary; no newer
release is implied by a source commit or a locally packaged app.

The packager assembles and validates self-contained app/ZIP artifacts and
supports Developer ID signing and notarization. A notarized distribution,
no-bypass Gatekeeper check, and installation on an independent supported Mac
have not been demonstrated. See the [release runbook](native-release.md).

## Current Application

| Area | Implemented behavior |
|---|---|
| Import and browsing | Standard images use a 1000px ImageIO preview. Camera RAW uses a colour-accurate draft, selected-file inspect and full-sensor 1-pass previews, and bounded neighbour lookahead. Supported gestures on a selected full RAW use a 2048px interaction raster followed by an exact full-source refinement. Sidebar thumbnails are separate. |
| Inspector | Develop, Geometry, Calibrate, and Export pages; full-output dimensions in the header. Develop contains Film & Inversion, Tone & Light, and Color & Balance. |
| Processing | Color/B&W negative, slide, and Original; Natural/Darkroom/Classic/Bypass conversion; reference looks and paper choices; tone, color, curves, wheels, dye crossover, and optional measured-density processing. B&W overall tone curves work on CPU and GPU. |
| Geometry | Auto Frame, freeform/fixed-ratio manual crop, two-point straighten, four-corner perspective, rotation/flip, frame and aspect padding. Shared dimension prediction and preview/export geometry. Changing upstream geometry invalidates the dependent manual canvas crop; clearing that manual crop retains upstream geometry. |
| Viewport | Fit, pan, pinch, zoom steps, and 100% current-preview pixels. Original comparison and source-resolution upgrades preserve the viewed region. Overlays convert gesture coordinates using native magnification. Selection changes fit the new image. |
| Edits and rolls | Per-file persisted settings; session-local undo/redo with gesture coalescing; presets, clipboard transfer, selected/all look application, navigation in sidebar order, and export-state sidebar markers. Post-Beta-2 source adds session-local up/down reordering. |
| Stacks | Opt-in adjacent repeated captures, translation alignment, Auto/Noise/HDR modes, bounded-to-full-resolution preview, and one export under the first capture's name/settings. Original captures merge in row bands through temporary disk storage; failures retain a usable preview and report status. |
| Export | Sequential full-resolution TIFF/JPEG/PNG/processed-RGB DNG, collision-safe naming, stage-boundary cancellation, and cleanup. The selected RAW may retain its last three-pass decode for settings-only re-export. |
| Contact sheets | Selected/all PDF export with 12 corrected previews per Letter-size page, filenames, sidebar order, and one merged tile per enabled stack. Edits are captured at start; Original comparison and open crop editors do not alter the output. Progress, cancellation, staged commit, and collision-safe names share the app export workflow. |
| Live camera | AVFoundation preview for devices exposed by macOS, with invert/exposure/saturation. Vendor-specific tethering is not implemented. |

## Processing And Memory Contracts

- Swift owns 16-bit BGR buffers returned through the narrow LibRaw C/C++ bridge.
  The CPU pipeline is the deterministic export/reference authority.
- Camera-scan export uses the frozen LibRaw 0.21.4 integer three-pass X-Trans
  oracle. Independent wavefront diagonals and Fuji compressed strips run across
  at most eight workers. `LIBRAW_FORCE_OPENMP` stays off because its overlapping
  X-Trans tiles fail the exact-output contract. This is not live RawTherapee parity.
- The [X-T5 compatibility adapter](raw-decode-compatibility.md) preserves the
  established uncropped source geometry and color conversion under LibRaw
  0.22.2. The newer library's active-area and matrix defaults otherwise change
  saved edits and frozen pixels. Other cameras and layouts retain LibRaw defaults.
- RAW preview bounds are 640 draft, 4000 inspect, and 3200 lookahead; actual
  dimensions follow CFA binning. One selected-file full-sensor 1-pass preview
  demotes on selection change. A separate selected-file export decode is also
  dropped on selection change. No full-resolution lookahead or roll-sized RAW
  cache is permitted. See [preview architecture](realtime-preview-plan.md).
- The preview cache defaults to eight sessions and has a 256 MiB byte bound.
  The model persists its count limit; the current inspector has no cache-size
  control. Render scheduling retains only the latest pending request. A selected
  full RAW retains an additional 2048px RGB16/RGBA16 interaction source; cache
  accounting includes it, while the selected full session remains exempt from
  the bounded background total.
- Stacks decode originals sequentially and use temporary disk space of roughly
  two bytes per channel per pixel per capture. Temporary files are removed on
  success, failure, and cancellation. A loaded flat field prevents stacking.
- CPU clipping diagnostics sample at most 65,536 pixels without full-frame
  Double expansion. Darkroom analysis shares sorted channel percentiles and
  retains pixel/chroma pairs during neutral-axis selection.
- TIFF/PNG are 16-bit sRGB; JPEG is 8-bit sRGB. Processed DNG stores 16-bit RGB
  with output-referred linear-sRGB metadata. TIFF compression defaults to none;
  LZW measurements must be identified explicitly.
- Contact-sheet tiles use 8-bit corrected previews bounded to 1000px. RAW
  captures decode sequentially through the shared gate, and each enabled stack
  merges its bounded captures before correction. Sheets do not use or populate
  the full-resolution export cache. Export borders/aspect padding are omitted.
- Manual-crop aspect ratios use the full-output canvas after upstream geometry,
  independent of viewport zoom or preview downsampling. Drawing and handle edits
  save a constrained normalized rectangle; processing still uses that rectangle
  with outward whole-pixel rounding. The per-file ratio survives history and
  relaunch, stays local during look transfer, and defaults to Free for old settings.

## Verification Summary

| Evidence | Latest recorded result | Scope |
|---|---|---|
| Full native release suite, September 14 | 628 tests reported: 616 passing records, 12 opt-in skips; 232.231 s | Final working-tree source, including local RAW references, repeated half-size determinism, one-worker Fuji unpacking, the bounded full-RAW edit proxy, persistence, geometry, stacks, contact sheets, output readers, and the three-frame roll. |
| Final RAW/roll check, September 14 | 10 tests passed; 79.517 s | After explicit serial Fuji unpack: camera-scan stages, serial/parallel equivalence, all five correction scenarios, five half-size RawPy references, repeated half-size determinism, full-size RawPy reference, and the real roll workflow. |
| Full native release suite, September 9 | 595 tests reported: 585 passing records, 10 opt-in skips; 460.024 s | Includes available RAW corpus, camera-scan identity, CPU/GPU Darkroom parity, app/geometry and source-editor history, fixed crop ratios, stacks, contact sheets, independent-reader output, and exact analysis/pixel references. Run with macOS graphics access. |
| CPU/Metal comparator, September 2 | 2,725 comparisons, zero render failures; maximum 2/255 (B&W 1/255) | Parameter-grid parity; fails if Metal is missing, no comparisons complete, rendering fails, or tolerance is exceeded. |
| Three-frame Fuji roll, September 4 | Opt-in workflow passed, 38.8 s | Look transfer, reversible exception, comparison, ordered TIFF export, retained-decode re-export, persisted settings, independent reader checks; outputs removed and source hashes unchanged. |
| Local packaged viewport, September 8 | Fit/100%/pan/Original and Fit-scale manual crop passed | Direct gesture mechanics on three RAFs; does not establish broad photographic quality. |
| Local packaged stack, September 8 | Proposal, Auto noise mode, alignment, and full-resolution preview passed | Three copies of one JPEG; real repeated-capture quality remains unverified. |
| Contact-sheet export, September 9 | Six release tests passed, including three real RAFs and 12/13/25-scan pagination | App-path snapshots, corrected PDF pixels, selection order, enabled stacks, collision handling, cancellation and retry. PDFKit and Poppler verified output; Computer Use testing is deferred. |
| Manual-crop ratios, September 9 | Seven release tests passed, including four app geometry cases | All nine fixed ratios, handle anchors/bounds, single-axis corner drags, zoom conversion, legacy settings, look-transfer isolation, Undo/Redo, relaunch, and exact preview/TIFF pixels. Includes downsampled browsing and rotated/perspective/straightened canvases; Computer Use testing is deferred. |
| Full-resolution edit scaling, September 14 | 12 focused release tests passed; isolated A/B probe passed | A real 7752 × 5184 RAW keeps its full logical canvas while supported gestures use a 2048px raster and release publishes current full-source parameters. The measured consumed-render median was 85.11 → 8.56 ms uncropped and 37.93 → 7.16 ms cropped; three samples per case, not presentation timing. |
| Analysis benchmark, September 8 | Textured Darkroom 103.34 → 43.83 ms p50; flat 7.37 → 5.14 ms | Isolated stages, five timed repetitions. Textured process peak 13.84 → 16.76 MB. All nine analysis/pixel hashes unchanged. |
| Formatting | Strict recursive Swift lint and diff whitespace check passed | Manifest, native sources, and tests. |

The September 9 release suite ran on macOS 15.7.9 (24G830), Apple M4 Pro,
48 GB RAM, and Swift 6.1.2 with normal macOS graphics access.

Geometry-history regression checks on September 8 reproduced an open crop
editor switching from its 188 × 258 uncropped canvas to a 123 × 182 cropped
preview after Undo. History restoration now preserves the active editing
canvas. All 29 focused geometry/comparison/viewport tests passed with macOS
graphics access, including crop, straighten, and reset undo/redo; continued
crop edits; persisted geometry; and returning to the committed crop after
editing ends. Geometry-rendered pixels match the CPU reference exactly; reset
can return to Metal and uses the existing 2/255 channel tolerance with row
padding excluded. This is automated app-model evidence; the packaged
photographic assessment remains open.

Source-editor regression checks on September 9 reproduced Undo, Reset,
exposure changes, and presets turning off Original while Perspective or
film-base sampling remained open. The shared edit-render path now preserves
Original for those source-based tools, and the Perspective toolbar locks the
comparison toggle just as film-base sampling does. All eight action/comparison
combinations passed: original source pixels remain within the existing 2/255
GPU tolerance, Undo restores persisted settings, closing restores the exact
previous composition/comparison, and later history reveals corrections normally.
This is automated app-model evidence; no new hands-on photographic assessment
is claimed.

Contact-sheet files were separately inspected with Poppler: the three-RAF
output has searchable filenames and three 966 × 648, 8-bit image tiles; the
25-scan fixture has three correctly numbered Letter pages without blank
trailing pages or clipped labels. All four rendered pages were visually
checked. These are output/layout checks, not photographic color or stack-quality
acceptance. The [test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md#independent-viewer-output-contract)
describes how to retain these PDFs for review.

A September 9 local package, version 0.2.0 build 20260909.3, passed assembled-app
and extracted-ZIP validation with ad-hoc signing. It contains the uncommitted
editor repairs, contact-sheet export, and fixed crop ratios on top of
`20a97c6984a9abd3744f8e7f15a8f00da60f1d41` and is available locally under
`dist/crop-ratios-2026-09-09/`. The archive
`Film-Scan-Converter-0.2.0-local-crop-ratios.20260909-apple-silicon.zip`
has SHA-256 `4cdbcc2ca8b022941251d8091718d0b7a75a34b16b210cb51e279fd26a1bdf8d`.
This development artifact does not establish notarization, a clean release
commit, or independent-Mac validation.

The [analysis report](../performance/preview-analysis.md) contains raw samples,
source hashes, and reproduction. The [40 MP export notes](../performance/40mp-export.md)
retain dated before/after measurements and decode-oracle provenance. Those
records are not a measurement of today's complete application.

Frozen fixtures require exact shared Python/OpenCV behavior where specified.
JPEG import has a separate decoder tolerance: maximum UInt16 difference 2,560,
mean difference 512, because ImageIO and OpenCV decode JPEG differently.

CI tests with coverage and builds the app on macOS 14 and 15. The macOS 15 lane
also enforces formatting and validates an unsigned beta archive. The standalone
comparator, opt-in roll/performance tests, and local RAW corpus are not default
CI evidence. Current local success is not a claim that a future pushed commit
has passed CI.

September 12 source follow-up repaired incomplete sidebar reordering, prevented
reorders during export, and invalidated disabled merged-preview cache entries.
It also moved full-size flat-field preparation out of preview submission and
into CPU density rendering. Eight focused release tests passed in 0.385 seconds,
including both density-field variants with exact preview pixels through geometry.
Builds used at most two jobs. No new full suite, RAW benchmark, or packaged-app
performance claim is made. The [research note](../performance/research-directions-2026-09-12.md)
records the findings and next experiments.

The [September 13 implementation](../performance/implementation-2026-09-13.md)
moves settings encoding/writes off the main actor, adds exact large-image
Natural B&W lookup processing, reuses Darkroom analysis, supports GPU manual
crops, and publishes completed edits during sustained input. Its focused tests
and bounded measurements are recorded separately from the earlier full suite.

The [September 14 RAW compatibility repair](raw-decode-compatibility.md) restores
the established X-T5 source geometry and camera-WB conversion with LibRaw
0.22.2. The camera-scan stage/pixel references and all five correction scenarios
pass without changing their fixtures. C/C++ boundary checks also pass against
0.22.2 and 0.21.4 headers; a direct decoder check against the original packaged
0.21.4 library retains the same stage hashes.

The final September 14 complete release suite ran with two build jobs, serial
tests, and normal macOS graphics access on macOS 15.7.9 (24G830), Apple M4 Pro,
48 GB RAM, Swift 6.1.2, and LibRaw 0.22.2. It reported 628 tests in 232.231 s,
including the final one-worker Fuji unpacking and bounded full-RAW edit proxy.
The three-frame roll passed, including edit transfer, comparison, selected
export/re-export, source hashes, and persisted settings. These are regression-run
durations, not a performance comparison with earlier suites.

Before that final run, all ten focused RAW/roll tests passed against the
one-worker unpack source in 79.517 s; the roll alone took 23.324 s. No frozen
fixture changed. Strict recursive Swift lint, C/C++ compatibility checks, shell
syntax, and diff whitespace checks pass. Local documentation links resolve;
MkDocs is unavailable in the local Python environment, so a complete
documentation-site build was not run.

The [September 14 preview-scale follow-up](../performance/preview-scale-2026-09-14.md)
measures source-sized edit rendering on the local real RAW and adds the bounded
continuous-edit raster described above. The exact full-source frame remains the
post-gesture authority. Its focused checks and the final 628-test release run do
not claim native-input or screen-presentation latency, energy improvement, or
photographic acceptance.

A September 14 local package, version 0.2.0 build 20260914.2, passed app and
extracted-ZIP validation with ad-hoc signing. It includes the working-tree
changes on top of `4e962c13552346f1b3a4b0bceeea92085b5cd0b0`, embeds LibRaw
0.22.2, and is under `dist/roadmap-2026-09-14/`. ZIP SHA-256:
`2ebb480a302bf7f03f8d180770e0346ec56da9fcaf7b5e6d007756a279bc67af`.
This is a local review artifact; notarization, independent-Mac installation,
and a release built from a clean commit with green CI remain open.

## Remaining Verification And Limitations

- Hands-on focus, grain, dust, tone, and color judgment across representative
  scans, including a realistic roll and real repeated captures.
- Preview/Photos judgment and install/launch proof on an independent Mac.
- Developer ID notarization and final distributed-artifact checks.
- Native dust removal/inpainting, lens-distortion correction, and vendor-specific
  tethering are absent. Sidebar reordering is session-local and uses up/down
  buttons; drag reordering is not implemented.
- Stack alignment handles translation only; flat-field correction is not applied
  to each capture before stacking, so the combination is disabled.
- Standard-image alpha is rejected. Some viewers cannot open processed-RGB DNG.
- The available real RAW regression set is X-Trans-focused and partly local-only;
  Bayer RCD has no committed real-file gate. Decode identity is a same-machine
  contract, not cross-platform byte identity. Review the adapted LibRaw body
  whenever upgrading that dependency.
- Measured-density processing uses CPU fallback. The offline affine fitter has
  synthetic validation but no validated built-in capture correction. Existing
  Natural curves and Darkroom unmix profiles have separate provenance.
- Further corpus preparation, named-stock fitting, residual LUTs, halation work,
  and ML are parked pending explicit owner direction.

## Build And Test

Use [Building](building.md) for commands, the [test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md)
for opt-in coverage, [Contributing](../contributing.md) for invariants, and
[native package documentation](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/README.md) for tool details.
