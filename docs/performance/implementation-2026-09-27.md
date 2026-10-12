# Native performance implementation — September 27, 2026

Five ranked opportunities were implemented in the native app. The saved CPU
comparison shows large reductions for the tested monochrome and viewport cases;
it does not establish a color-rendering speedup.

This is the September 27 implementation cohort. The later
[September 28 scalar/overview follow-up](cpu-point-work-2026-09-28.md) and
[October 2 density/I/O follow-up](implementation-2026-10-02.md) build on it;
their numbers use separate measured sources and workloads. Use
[development status](../development/native-macos.md#verification-summary) for
the latest checks, and preserve the source/limits of the results below.

## Implemented changes

1. **CPU geometry viewport correction.**
   [`CPUPreviewPreparationCache`](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/FilmScanEngine/CPUPreviewPreparationCache.swift)
   retains complete geometry, a sensor overview bounded at 2,048px, and immutable
   full-sensor analysis. Interactive photographic requests correct that overview
   plus exact visible detail. `AppModel` publishes the complete raster on settle;
   legacy, density/flat-field and crop-only requests retain their existing routes.
   Geometry/overview bytes now participate in cache accounting and admission.
   This reduces correction after preparation; the first complete warp remains.
2. **Prepared CPU inversion, tone and protected color.**
   [`PhotographicProcessing`](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/FilmScanEngine/PhotographicProcessing.swift)
   prepares settings-dependent gains, exact curve knots, tail rates, clamps,
   tone endpoints and color controls before its bounded correction workers.
   Monochrome skips discarded calibrated-color gains. Pixel arithmetic order,
   tone versions 1–4, full-sensor analysis, profiles and defaults are preserved;
   no quantized lookup table was introduced. Scalar entry points remain oracles.
   `PreparedProcessingStateTests` checks exact Double bit patterns, boundaries,
   profiles, protected colors, and serial/parallel buffers.
3. **Lazy preview RGBA backing with conservative reservation.**
   [`StillPreviewRenderer`](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/FilmScanPreviewRenderer/StillPreviewRenderer.swift)
   retains the UInt16 source and packs RGBA16 once on first supported correction.
   CPU routes can leave it unmaterialized. At 7,752×5,184, this defers one
   **321,490,944-byte (306.6 MiB)** allocation; the original source remains.
   This is deferred allocation, not a measured permanent process-memory saving,
   and may shift packing latency to the first correction. `PreviewSessionCache`
   tracks actual bytes while reserving maximum eventual backing for admission.
4. **Ancillary preparation outside the main actor.**
   [`AppModel`](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/FilmScanConverterMac/AppModel.swift)
   schedules flat-field decode and moves rebate field preparation plus dust
   geometry, mask conversion, bitmap packing and counting to workers. Cancellation
   and generations reject stale loads, selections and source-tier upgrades.
   Clearing a crop also cancels dust work. Export/flat-field guards preserve
   calibration consistency. No action-to-screen latency gain was measured.
5. **Bounded export writer overlap.**
   [`ExportManager.exportOne`](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/FilmScanEngine/ExportManager.swift)
   is nonisolated so synchronous packing/ImageIO work leaves the orchestration
   actor. Existing concurrency limits, input-ordered results, cancellation before
   writes, stage draining and cleanup remain. The `ExportTests` writer gate proves
   two active writers at a limit of two, out-of-order completion with ordered
   results, and cancellation/failure cleanup. It is not a throughput benchmark.

## CPU A/B measurement

The release probe (`dist/performance-implementation-2026-09-27/CPUProbe.swift`)
ran **three timed exposure values per case** (`0.2`, `-0.2`, `0.4` EV), without
concurrent builds/tests. An initial baseline was followed by a final ordinary
release candidate and then a frozen-baseline recheck. The final candidate uses
the same production build kind as the baseline. An earlier candidate linked
after a test build is retained as diagnostic evidence and excluded from this table.
Each case first rendered a complete frame outside timing, warming complete CPU
geometry and analysis. The only input was private `fuji400-fresh/DSCF2833.RAF`:
camera-scan decode with `maxDimension: 100_000`, yielding 7,752×5,184 pixels.
This is a full-sensor one-pass preview source, not a three-pass RAW export.
The harness records presets, medians, controls and geometry. Source, input,
harness and binary hashes are saved in the
comparison (`dist/performance-implementation-2026-09-27/cpu-comparison.json`).

Measurements and verification used Apple M4 Pro (Mac16,7), 48 GiB RAM,
macOS 15.7.9, Swift 6.1.2 and LibRaw 0.22.2. The photographic cases use tone
version 4; geometry and density analysis are anchored to the complete sensor.

| Case | Initial baseline seconds | Production candidate seconds | Baseline recheck seconds | Lower measured time |
|---|---:|---:|---:|---:|
| C-41 complete frame | 6.589 | 6.740 | 6.805 | Not established |
| Cyan-mask complete frame | 6.641 | 6.784 | 7.198 | Not established |
| Monochrome complete frame | 6.923 | 3.388 | 7.005 | 51–52% |
| Straightened viewport | 6.874 | 0.619 | 7.943 | 91–92% |
| Perspective viewport | 5.340 | 0.652 | 5.689 | 88–89% |

Full-frame timers cover complete CPU correction; hashes cover complete UInt16
outputs. Viewport baseline timing covers full correction, then crops outside
timing. Candidate timing covers overview plus **exact 1,200×800 detail at
`(256, 128)`**, including first overview creation; the returned overview is
bounded at 1,024px. Viewport hashes cover detail, not the resized overview.
All **15** candidate full-frame/detail hashes match, as do the 15 baseline
recheck hashes. Viewport percentages compare work
needed for this interactive request, not two complete-raster renders.

The color candidate medians fall between the two baseline medians. Baseline
variation prevents a reliable color improvement claim. This one-frame study
needs broader counterbalanced runs before generalizing any result. Every window
excludes **decode, first warp, bitmap packing, writing, main-actor publication
and screen presentation**. It establishes neither export throughput nor screen
latency; its percentages cannot be added to earlier decode/render improvements.

## Verification

- The earlier focused release run reported **71 tests passed**, with one opt-in
  export cohort skipped, before the final `Clear Crop` regression fix/test.
- Final full native release suite: **759 tests, 17 reported skipped checks,
  zero issues**, 290.108 seconds after an 83.76-second build.
- Standalone CPU/Metal comparator: **4,608/4,608 cases**, comprising 4,164 GPU
  comparisons within 2/255 and 444 explicit CPU routes; zero failures.
- All **five fresh preferred-look PNGs** match exact ledger hashes; the
  preference ledger is unchanged.
- The six-frame photographic app check passed (205.540 seconds): all six
  7,752×5,184, 16-bit named-sRGB TIFFs reopened with exact production CPU pixels.
  Same-source app and Metal previews differ by at most 1/255. The one-pass
  preview and three-pass export use different source pixels; their recorded
  maximum differences of 98–250/255 are separate from same-source agreement.
- Strict package-wide Swift formatting and whitespace checks pass. The standalone
  production build of `FilmScanConverterMac` passes (35.34 seconds).

## Evidence

The ignored `dist/performance-implementation-2026-09-27/` root contains
before (`dist/performance-implementation-2026-09-27/cpu-before.json`) and
production candidate samples (`dist/performance-implementation-2026-09-27/cpu-after-production.json`),
baseline recheck (`dist/performance-implementation-2026-09-27/cpu-before-confirmation.json`), the
source manifest (`dist/performance-implementation-2026-09-27/source-manifest.json`)
and full suite log (`dist/performance-implementation-2026-09-27/full-native.log`).
Base HEAD: `2b4da0930df3ccebc08c1e3197a8ec242df448ac`. Private inputs/images
remain in `sample-raw/` and `dist/`. Use fresh output after source/input changes.
