# Native macOS Development Status

This page owns current implementation status, verification, and limitations.
[Features](../features.md) describes the user tools; the
[roadmap](../improvements/MacOS-Native-Roadmap.md) owns priority.

**Verified September 8, 2026 against the current source.** Local RAW tests depend
on the untracked `sample-raw/` corpus; CI cannot reproduce those cases without it.

## Release Position

The native Swift/SwiftUI app is the primary product. The latest published
binary is [0.2.0 Beta 1](https://github.com/athoma28/Film-Scan-Converter/releases/tag/v0.2.0-beta.1)
(August 14, 2026), an ad-hoc-signed Apple Silicon build for macOS 14 or later.
Current source includes features and repairs beyond that binary. No newer
release is implied by a source commit or a locally packaged app.

The packager assembles and validates self-contained app/ZIP artifacts and
supports Developer ID signing and notarization. A notarized distribution,
no-bypass Gatekeeper check, and installation on an independent supported Mac
have not been demonstrated. See the [release runbook](native-release.md).

## Current Application

| Area | Implemented behavior |
|---|---|
| Import and browsing | Standard images use a 1000px ImageIO preview. Camera RAW uses a colour-accurate draft, selected-file inspect and full-sensor 1-pass previews, and bounded neighbour lookahead. Sidebar thumbnails are separate. |
| Inspector | Develop, Geometry, Calibrate, and Export pages; full-output dimensions in the header. Develop contains Film & Inversion, Tone & Light, and Color & Balance. |
| Processing | Color/B&W negative, slide, and Original; Natural/Darkroom/Classic/Bypass conversion; reference looks and paper choices; tone, color, curves, wheels, dye crossover, and optional measured-density processing. B&W overall tone curves work on CPU and GPU. |
| Geometry | Auto Frame, manual crop, two-point straighten, four-corner perspective, rotation/flip, frame and aspect padding. Shared dimension prediction and preview/export geometry. Changing upstream geometry invalidates the dependent manual canvas crop; clearing that manual crop retains upstream geometry. |
| Viewport | Fit, pan, pinch, zoom steps, and 100% current-preview pixels. Original comparison and source-resolution upgrades preserve the viewed region. Overlays convert gesture coordinates using native magnification. Selection changes fit the new image. |
| Edits and rolls | Per-file persisted settings; session-local undo/redo with gesture coalescing; presets, clipboard transfer, selected/all look application, import-ordered navigation, and export-state sidebar markers. |
| Stacks | Opt-in adjacent repeated captures, translation alignment, Auto/Noise/HDR modes, bounded-to-full-resolution preview, and one export under the first capture's name/settings. Original captures merge in row bands through temporary disk storage; failures retain a usable preview and report status. |
| Export | Sequential full-resolution TIFF/JPEG/PNG/processed-RGB DNG, collision-safe naming, stage-boundary cancellation, and cleanup. The selected RAW may retain its last three-pass decode for settings-only re-export. |
| Live camera | AVFoundation preview for devices exposed by macOS, with invert/exposure/saturation. Vendor-specific tethering is not implemented. |

## Processing And Memory Contracts

- Swift owns 16-bit BGR buffers returned through the narrow LibRaw C/C++ bridge.
  The CPU pipeline is the deterministic export/reference authority.
- Camera-scan export uses the frozen LibRaw 0.21.4 integer three-pass X-Trans
  oracle. Independent wavefront diagonals and Fuji compressed strips run across
  at most eight workers. `LIBRAW_FORCE_OPENMP` stays off because its overlapping
  X-Trans tiles fail the exact-output contract. This is not live RawTherapee parity.
- RAW preview bounds are 640 draft, 4000 inspect, and 3200 lookahead; actual
  dimensions follow CFA binning. One selected-file full-sensor 1-pass preview
  demotes on selection change. A separate selected-file export decode is also
  dropped on selection change. No full-resolution lookahead or roll-sized RAW
  cache is permitted. See [preview architecture](realtime-preview-plan.md).
- The preview cache defaults to eight sessions and has a 256 MiB byte bound.
  The model persists its count limit; the current inspector has no cache-size
  control. Render scheduling retains only the latest pending request.
- Stacks decode originals sequentially and use temporary disk space of roughly
  two bytes per channel per pixel per capture. Temporary files are removed on
  success, failure, and cancellation. A loaded flat field prevents stacking.
- CPU clipping diagnostics sample at most 65,536 pixels without full-frame
  Double expansion. Darkroom analysis shares sorted channel percentiles and
  retains pixel/chroma pairs during neutral-axis selection.
- TIFF/PNG are 16-bit sRGB; JPEG is 8-bit sRGB. Processed DNG stores 16-bit RGB
  with output-referred linear-sRGB metadata. TIFF compression defaults to none;
  LZW measurements must be identified explicitly.

## Verification Summary

| Evidence | Latest recorded result | Scope |
|---|---|---|
| Full native release suite, September 8 | 580 tests reported: 570 passing records, 10 opt-in skips; 293.059 s | Includes available RAW corpus, camera-scan identity, CPU/GPU Darkroom parity, app/geometry, stack, independent-reader output, and exact analysis/pixel references. Run with macOS graphics access. |
| CPU/Metal comparator, September 2 | 2,725 comparisons, zero render failures; maximum 2/255 (B&W 1/255) | Parameter-grid parity; fails if Metal is missing, no comparisons complete, rendering fails, or tolerance is exceeded. |
| Three-frame Fuji roll, September 4 | Opt-in workflow passed, 38.8 s | Look transfer, reversible exception, comparison, ordered TIFF export, retained-decode re-export, persisted settings, independent reader checks; outputs removed and source hashes unchanged. |
| Local packaged viewport, September 8 | Fit/100%/pan/Original and Fit-scale manual crop passed | Direct gesture mechanics on three RAFs; does not establish broad photographic quality. |
| Local packaged stack, September 8 | Proposal, Auto noise mode, alignment, and full-resolution preview passed | Three copies of one JPEG; real repeated-capture quality remains unverified. |
| Analysis benchmark, September 8 | Textured Darkroom 103.34 → 43.83 ms p50; flat 7.37 → 5.14 ms | Isolated stages, five timed repetitions. Textured process peak 13.84 → 16.76 MB. All nine analysis/pixel hashes unchanged. |
| Formatting | Strict recursive Swift lint and diff whitespace check passed | Manifest, native sources, and tests. |

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

## Remaining Verification And Limitations

- Hands-on focus, grain, dust, tone, and color judgment across representative
  scans, including a realistic roll and real repeated captures.
- Preview/Photos judgment and install/launch proof on an independent Mac.
- Developer ID notarization and final distributed-artifact checks.
- Native dust removal/inpainting, lens-distortion correction, manual sidebar
  reordering, and vendor-specific tethering are absent.
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
