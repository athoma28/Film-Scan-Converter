# Test Suite

This directory contains legacy Python regression tests, compatibility-fixture
generators, and native benchmark helpers. The Python pipeline is no longer the
design authority for new features. Shared historical behavior is frozen here
for compatibility while new native behavior uses deterministic Swift CPU
contracts. See
[Native macOS Development](../docs/development/native-macos.md) for current
verification and [Legacy Python Application](../docs/legacy-python.md) for
the retirement policy.

This page owns commands, test switches, fixtures, and check scope. Test outcomes
belong in development status; performance results belong in the
[performance index](../docs/performance/index.md). Keep counts out of this command
inventory so changes to a suite do not silently stale its procedure.

## Native Regression

From the repository root, run with normal macOS graphics access:

```sh
bash native/test-raw-compatibility.sh
swift test --package-path native/FilmScanEngine --no-parallel
```

The C/C++ compatibility checks require LibRaw headers and `pkg-config`, and run
without RAW files. They guard the X-T5 adapter's geometry/color boundaries and
compare directional X-Trans homogeneity against independent original-order loops
at `-O3`, including special floating-point values, partial tiles, and canaries;
the Swift camera-scan and RawPy fixtures remain the actual pixel authority.
See [RAW upgrade compatibility](../docs/development/raw-decode-compatibility.md).

Use `-c release` for performance comparisons. Default native runs skip opt-in
benchmarks and the representative roll workflow. RAW-dependent tests explicitly
skip when their local inputs are unavailable. Latest test counts and platform
coverage are recorded in [development status](../docs/development/native-macos.md).

The committed native CI workflow runs this regression gate with code coverage
on macOS 14 and 15, builds the app on both, and checks Swift formatting and
assembles an unsigned beta on macOS 15. CI does not contain the private RAW
corpus or enable the performance/roll gates. A passing CI run therefore does not
establish local RAW parity, packaged-app interaction, or current performance.

For a focused RAW metadata and Xcode 16.2 assertion-compatibility check:

```sh
swift test --disable-sandbox -c release --package-path native/FilmScanEngine \
  --no-parallel --filter 'RawImageDecoderTests|SustainedPreviewPerformanceTests'
```

This compiles the sustained-preview harness but leaves its measurement disabled
unless explicitly enabled. Keep throwing work and compound budget calculations
outside test macros so the supported older toolchain can compile the assertions.

### Current default coverage

These suites cover the current film-base/look workflow and preview changes;
they are part of the default run, not opt-in benchmarks:

| Suites | Contract |
|---|---|
| `FilmBaseRecipePreviewTests` | CPU/Metal parity for current bases, all factory recipes across editable bases, public color endpoints, and Original bypass; odd-sized chromatic rasters exercise row padding. Flat density inputs must use the CPU fallback; app-path coverage checks displayed pixels. Unexpected renderer failures fail explicitly. |
| `LookRecipeTests`, `LookRecipeAppTests` | Factory looks are reproducible public-slider snapshots; applying them needs no decoded image and preserves the film base; save/load and undo retain the same values. |
| `PhotoAdjustmentParametersTests`, `PhotographicToneTests`, `FocusedToneResponseTests`, `GradingPointControlTests` | New edits use tone version 4, older saved versions retain their response, and factory looks stay on version 2. Focused light ranges and grading-point controls keep their endpoint and parser contracts; the version-3 trial remains an explicit comparison. Saved-number validation includes optional foliage recovery; tone monotonicity covers all 1,024 independent endpoint combinations. |
| `AdjustmentValueEditingTests`, `AdjustmentValueFieldInteractionTests` | Locale-aware exact input, invalid/nonfinite rejection, range/step constraints, untouched precision, source-safe drafts, keyboard increments, and native field Return/Escape/focus-loss behavior. Native events get separate run-loop opportunities; field-editor ownership and responder resignation are verified. This does not establish rapid native-input acceptance. |
| `WorkspaceLayoutTests` | Prior panel arrangement restoration, inspector commands, and a hosted minimum-size native window retaining viewport identity, magnification, pan, and inspector width through resize/collapse. |
| `PresetPreviewTests` | Production thumbnail pixels, immutable sensor analysis, source/local-setting invalidation, stale worker suppression, and all-or-nothing budget fallback. The full-strip timing benchmark is opt-in. |
| `PhotoAdjustmentEditingTests` | Public sliders clamp to their advertised ranges, reject nonfinite input before changing parameters or Original comparison, and keep tone-version promotion inside the same undoable gesture. |
| `AppModelObservationTests` | Preview publication and delayed statistics do not invalidate parameter controls, preview availability, or undo menus. Availability follows loading and deselection; completed gestures still update history observers. |
| `PresetWorkflowTests` | Version-one preset migration preserves destination film base/framing, backs up the original document before a write, rejects unknown schemas, reports save failures, and avoids redundant renders. Develop reset preserves calibration and geometry. |
| `CorrectionClipboardTests` | Clipboard reads are cached by revision, malformed/stale reads invalidate correctly, providers without revisions stay fresh, and failed writes are reported. Valid full paste ends an active gesture with separate undo/persistence; empty or invalid paste preserves coalescing. |
| `SelectiveAdjustmentTransferTests` | Independent adjustment groups, exposure exclusion, tone-version rules, atomic legacy rejection, matching/empty no-ops, clipboard targets, undo, persistence, and preservation of local framing/calibration/repairs. |
| `ExportDestinationTests`, `ExportPreparationCancellationTests` | Original-folder defaults, queue snapshots, per-folder reservation and late destination collisions, source preservation, contact sheets, cancellation before the next standard-image decode, completed-output counts, cleanup and retry. |
| `DustRepairTests`, `DustRepairAppTests` | Deterministic local texture/color healing, frozen automatic donors, complete-mask exclusion including skipped/capped components, bounded work, direct-stroke every-dab applicability with mark/history preservation, conservative component consumption, cancellation ownership, flat-field isolation, CPU routing/cache invalidation, saved/undoable repairs, framing, and reopened synthetic PNG agreement. Real-scan restoration quality remains separate. |
| `AutoFrameAppTests` | Current-source publication, geometry/threshold invalidation, history/source-upgrade rejection, direct cancellation, replacement busy ownership, and preservation of intervening tone edits with separate undo during a held gesture. |
| `LookTransferWorkflowTests` | Applying a look to selected/all classified scans protects those edits from later roll-hint reclassification; undo/redo restores both the look and classification eligibility. |
| `PerFileSettingsPersistenceTests` | Coalesced saves, failure/retry, and relaunch behavior; malformed or unsupported settings remain byte-for-byte intact, and recovery preserves other files across subsequent saves. |
| `OpenRollPersistenceTests`, `OpenRollAppTests` | Ordered roll and selection recovery, offline paths, close/reimport with preserved corrections, coalesced latest snapshots, failed-save retry, malformed/unknown-document preservation, and closing guards during export. |
| `PreviewRetentionTests`, `ViewportRenderingTests` | Completed rasters are reused during navigation/panning; edits, geometry, and flat fields invalidate them; byte limits and memory pressure preserve the selected image. Count/exhausted-byte admission skips unusable lookahead before decoding; foreground loading and cache expansion remain available. Active edits refine back to the complete raster. |
| `RetainedCanvasPreviewCacheTests`, `RetainedCanvasNavigationTests` | Independent half-size sRGB canvas storage, original-provider release, byte/count LRU, immediate RAW revisit after session eviction, full logical zoom dimensions, lower-tier suppression, edit/Original invalidation, and flat-field/pressure/Close All cleanup. Navigation uses injected deterministic RAW tiers. |
| `PhotographicConversionTests` | Bounded parallel initial photographic conversion matches serial tiles exactly across inversion branches, tone versions 2–4, and an uneven final scratch band. |
| `PreviewSessionCacheTests`, `CPUPreparationRetentionTests`, `CPUPreparationDiscardTests`, `CPUPreparationGPUTransitionTests` | The cache owns decoded sources, full/proxy CPU preparation and completed rasters together. Tests cover dynamic geometry bytes, cached reuse, display reservation, speculative rejection, LRU eviction, stale-worker growth, upgrades, pressure/Close All, and incompatible CPU-buffer release on GPU/density transitions without rebuilding matching geometry. |
| `AuxiliaryImageWorkTests` | Flat-field decoding runs off the main thread while input proceeds. New loads, Clear, and direct replacement invalidate held results; stale success/failure cannot overwrite the current field or status. Both export paths wait for pending calibration. Clear Crop removes completed and pending dust overlays. |
| `PreparedProcessingStateTests` | Prepared tone, protected-color, and calibrated-inversion state retains the scalar operation sequence and exact values across saved tone versions, control endpoints, extended values, and serial/parallel pixel buffers. |
| `CPUGeometryViewportTests` | Eligible CPU geometry edits correct an overview plus exact visible pixels using immutable sensor analysis. Geometry is reused, unsupported paths retain complete rendering, and gesture release publishes the complete raster with current parameters. |
| `ExportTests` | Independent synchronous writers overlap within the requested limit; results retain input order. Cancellation during active writes leaves pending jobs unwritten, and mixed success/failure preserves existing destinations and removes staging files. |
| `PreviewStatisticsMemoizationTests`, `PreviewPublicationTests`, `WheelEditingPerformanceTests` | Lazy statistics compute once per raster, cached reads never wait for a running sample, and revisions reject stale diagnostics. Releasing a complete edit refreshes statistics without duplicate correction; each wheel event publishes one combined value and a drag remains one persisted undo step. |
| `RawDecodeSchedulerTests`, `CPUPreparationPerformanceTests`, `StillPreviewPerformanceTests` | RAW priority/cancellation and bounded concurrency, reusable CPU geometry/analysis, banded pixel equivalence, bounded renderer-analysis caches, and lazy RGBA16 source materialization that happens once with maximum backing reserved before cache admission. Native RAW cancellation/parity cases still require local inputs. |
| `SampleRawCorpusTests`, `Lucky200PresetTests` | Reference-input hash/metadata errors and the warm-hue/neutral-prior math and migration contracts. Synthetic checks do not establish stock-wide color quality. |

Preview pixel comparisons share `PreviewPixelAssertions.swift`. They validate
bitmap layout, dimensions, provider availability, and complete visible RGB buffers
before indexing; row padding and skipped alpha are excluded from color assertions.
The deterministic odd-sized all-film smoke case complements the existing CPU/Metal
parameter grids. Repeated identical tone inputs live in the dedicated tone test,
and TIFF/PNG use one shared 16-bit RGB layout test alongside separate format
round-trip, boundary-sample, and collision-cleanup checks.

Saved-adjustment serialization is owned by `PhotoAdjustmentParametersTests`:
all supported versions, all controls, omitted neutral values, unknown versions,
and nonfinite inputs. Tone/rendering suites retain their distinct response and
real-parser contracts. Consolidated white-balance and saturation fixtures retain
every original input and tolerance as named argument cases. Monochrome curve and
color-only control tests compare pixels; orientation, resize, and straighten tests
use distinct samples and independent expected geometry. Dye/density parity also
checks meaningful GPU alpha while excluding skipped CPU storage bytes.

For the saved-controls and dye/density assertion checks:

```sh
swift test --disable-sandbox -c release --package-path native/FilmScanEngine --no-parallel \
  --filter 'PhotoAdjustmentParametersTests|FocusedToneResponseTests|FilmDyeMixingTests|DensityPrintProcessingTests'
```

For the legacy fixture, monochrome, wheel, and basic-inversion pixel assertions:

```sh
swift test --disable-sandbox -c release --package-path native/FilmScanEngine --no-parallel \
  --filter '(^|[.])(ProcessingTests|FilmDyeMixingTests)[./]'
```

Run a focused subset with SwiftPM's `--filter`, for example:

```sh
swift test --package-path native/FilmScanEngine --no-parallel \
  --filter 'LookRecipe|PresetWorkflow|CorrectionClipboard|PreviewRetention'
```

For workspace and numeric-entry regressions, run with normal macOS window access:

```sh
swift test --disable-sandbox -c release --package-path native/FilmScanEngine --no-parallel \
  --filter 'WorkspaceLayoutTests|AdjustmentValueEditingTests|AdjustmentValueFieldInteractionTests|AdjustmentSliderTests|PresetPreviewTests'
```

The optional complete preset-strip benchmark includes five fresh calculations
per synthetic/RAW cohort, including source preparation and bitmap packing. RAW
decoding occurs before timing, matching the already-loaded app source. The test
requires its four named local RAW inputs and fails if any complete strip exceeds
500 ms. Use a fresh ignored output directory after changing inputs or code:

```sh
RUN_PRESET_PREVIEW_BENCHMARK=1 \
PRESET_PREVIEW_BENCHMARK_OUTPUT="$PWD/dist/preset-preview-study/report.json" \
swift test --disable-sandbox -c release --package-path native/FilmScanEngine --no-parallel \
  --filter PresetPreviewTests
```

For the adjustment and cache cleanup regressions, including cancellation gates:

```sh
swift test -c release --package-path native/FilmScanEngine --no-parallel \
  --filter 'PhotoAdjustment|GradingPoint|PhotographicTone|PreviewSessionCache|RawDecodeScheduler|canceledQueuedAuthoritativeDecodeDoesNotStart'
```

These are default behavioral checks, not timing benchmarks. Scheduler tests hold
workers behind cancellable, bounded gates; the authoritative-decoder cancellation
test queues the second request while the first is explicitly held. Neither relies
on a short sleep to establish queue order. The native RAW interruption test still
uses a delay to request cancellation during real decoding and requires the corpus.

For auxiliary workers, prepared CPU state, CPU viewport rendering, independent
export writers, and lazy renderer backing, run this focused default subset with
normal macOS graphics access:

```sh
swift test --disable-sandbox -c release --package-path native/FilmScanEngine --no-parallel \
  --filter 'AuxiliaryImageWorkTests|PreparedProcessingStateTests|CPUGeometryViewportTests|ExportTests|StillPreviewPerformanceTests|PreviewSessionCacheTests'
```

Writer tests hold synchronous workers behind bounded gates to establish overlap
and cancellation, and assert progress callbacks for successful, failed, and
cancelled jobs. Auxiliary-worker tests await the actual task completion before
checking stale publication; current flat-field failures and cancellation must
release the export gate and permit retry. Pixel comparisons check dimensions,
bitmap layout, and complete buffer lengths before comparing channels. These
checks establish behavior and pixel contracts; they do
not measure throughput, UI presentation latency, or physical-memory savings.

For the October 2 density/dust, bounded I/O, thumbnail, and preview-invalidation
changes, use this focused release gate with normal macOS graphics access:

```sh
swift test --disable-sandbox -c release --package-path native/FilmScanEngine --no-parallel \
  --filter 'DensityPrintLookupTests|DustMorphologyTests|DustDetectionTests|BoundedIOTests|ScanStackingTests|PreviewWorkReuseTests|PreviewPublicationTests|RasterImageTests|embeddedThumbnail|sharedThumbnailSourceDimensions|ExportTests|IndependentViewerOutputTests'
```

The lookup checks every UInt16 code's exact Double result. Dust closing uses an
independent repeated-neighborhood oracle. I/O tests check exact DNG strip bytes,
bounded writes, partial bands, reference-spool removal, translated stack parity,
failure/cancellation cleanup, and independent-reader tags. Preview tests hold
workers at stage boundaries to establish invalidation and useful point-edit
publication without relying on execution timing. The RAW metadata subset needs
the private corpus and explicitly skips when absent. These are correctness gates;
the [implementation report](../docs/performance/implementation-2026-10-02.md)
separately records production timing, memory evidence, and their limits.

For TIFF, PNG, and processed DNG writer changes, run this focused regression gate
with normal macOS graphics access:

```sh
swift test --disable-sandbox -c release --package-path native/FilmScanEngine --no-parallel \
  --filter 'ExportTests|BoundedIOTests|ExportDestinationTests|IndependentViewerOutputTests'
```

PNG cases require exact 16-bit sample round trips, named sRGB and ICC data,
no alpha, and correct dimensions for single-pixel, single-row, single-column,
and odd-sized images. The largest synthetic case spans every UInt16 code in
distinct channels. Fixed Average filtering is lossless, but compressed output
bytes may change. DNG cases guard unchanged strip bytes, the 16 MiB packing
bound, and partial-band writes; destination cases cover staged commit and cleanup.
These are correctness checks, separate from export timing.

For the 0.3 adjustment, export-destination, and dust workflows:

```sh
swift test --disable-sandbox -c release --package-path native/FilmScanEngine --no-parallel \
  --filter 'SelectiveAdjustmentTransferTests|CorrectionClipboardTests|AutoFrameAppTests|ExportDestinationTests|ExportPreparationCancellationTests|DustRepairTests|DustRepairAppTests'
```

These checks cover grouped transfer/history, frozen per-folder queue destinations,
physical-folder aliases, encoded output formats, editable masks, saved source-space
repairs, and synthetic full-size export pixels. Dust checks exercise malformed
strokes independently, atomic rejection, resource boundaries, stationary pointer
samples, immutable donors, and displayed pixels when toggling repairs/Original.
Real-scan detection accuracy and grain/edge restoration require photographic review.

For open-roll recovery and Close All Scans:

```sh
swift test --package-path native/FilmScanEngine --no-parallel \
  --filter 'OpenRollPersistenceTests|OpenRollAppTests'
```

These default suites use temporary stores and copies of committed standard-image fixtures.
They cover saved order and primary/multiselection, unavailable source paths,
correction preservation with fresh undo history, protected unreadable documents,
latest-snapshot writes and retries, and closing during background work or export.
They do not require the private RAW corpus or establish packaged-app interaction.

For the half-size RAW revisit cache and bounded photographic export conversion:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/fsc-revisit-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/fsc-revisit-swift \
swift test --disable-sandbox -c release \
  --package-path native/FilmScanEngine --jobs 2 --no-parallel \
  --filter 'RetainedCanvas|PreviewRetentionTests|PreviewSessionCacheTests|PreviewWorkReuseTests|PreviewPublicationTests|PhotographicConversionTests|ExportTests|RawDetailRequestTests|PreviewViewportTests|PreviewComparisonTests|OpenRollAppTests|DustRepairAppTests'
```

The synthetic navigation cases use injected RAW tiers to force eviction and hold
upgrades deterministically. They establish model publication and ownership, not
native screen latency. Current-film-base JPEG timings use
`FilmScanExportBenchmark --film-base=colorC41`; see the
[October 10 export evidence](../docs/performance/jpeg-export-2026-10-10.md)
for the exact input/options and baseline comparison.

## Legacy Python Regression

The Python regression suite is deterministic and dependency-light:

```sh
.venv/bin/python -m unittest discover -s tests -p 'test_*.py'
```

It verifies pixel equivalence against reference implementations for thresholding, dust detection, histogram equalization, histogram rendering, exposure, white balance, and contour overlays. It also verifies cache invalidation, multiprocessing serialization, processing-counter cleanup after exceptions, failed-write reporting and retry behavior, batch-export UI restoration, and export error-dialog formatting.

`generate_native_snapshots.py` also writes the standard-image decode fixtures
used by the Swift regression gate. They lock exact Python/OpenCV-equivalent
pixels for 8-bit color PNG, 8-bit grayscale PNG, BMP, and 16-bit TIFF inputs.
The JPEG fixture permits maximum UInt16 difference 2,560 and mean difference
512 because
ImageIO and OpenCV use different lossy JPEG decoders.

## RAW Corpus And Decode References

`generate_raw_decode_reference.py` writes a compact manifest of dimensions,
color descriptions, and SHA-256 pixel hashes for the five representative
half-size RAF decodes plus one full-resolution decode. The Swift LibRaw tests
consume that manifest and require exact RawPy equality when `sample-raw/` is
present. A separate camera-scan fixture,
`native/FilmScanEngine/Tests/FilmScanEngineTests/Fixtures/camera_scan_decode_reference.json`,
pins the full-resolution `rawTherapeeCameraScan` decode of
`fuji400-fresh/DSCF2833.RAF` (stage digests plus Swift pixels). When the
untracked RAF corpus is absent, default corpus-specific Swift tests are reported as
disabled with an explicit reason rather than silently passing.
The RAF files remain outside version control. Discovery is recursive so the
corpus can be organized by film stock; manifests and benchmark reports store
root-relative paths, and ambiguous historical basenames are rejected.

Regenerate committed compatibility fixtures only for an intentional change to
the shared legacy contract, not to make a failing test pass. For example:

```sh
.venv/bin/python tests/generate_raw_decode_reference.py \
  --file misc/DSCF2819.RAF \
  --file fuji400-fresh/DSCF2833.RAF \
  --file fuji200-expired/DSCF3160.RAF \
  --file shanghaigp3/DSCF3200.RAF \
  --file cinestill800t/DSCF3247.RAF \
  --full-resolution-file fuji400-fresh/DSCF2833.RAF
```

## Performance Benchmarks

Performance benchmarks are opt-in so normal test runs remain stable:

```sh
RUN_PERFORMANCE_TESTS=1 .venv/bin/python -m unittest tests.test_performance -v
```

The ordinary `FilmScanExportBenchmark` uses its historical legacy correction
workload unless `--film-base=colorC41|colorCyanMask|blackAndWhite|slide|original`
selects the current neutral photographic controls with tone version 4.
`--tiff-compression=none|lzw` chooses TIFF compression and defaults to LZW;
the app defaults to None. Both choices are recorded in report configuration.
Determinism and correction-scenario modes keep fixed LZW TIFF output and reject
`--film-base`, `--formats`, and any explicit `--tiff-compression` flag.
See the [engine benchmark commands](../native/README.md#benchmarks-and-diagnostics).

The deterministic Metal adjustment benchmark runs a fixed 1080×720 workload
with dye crossover, protected tone/color controls, curves, and color wheels:

```sh
swift run -c release --package-path native/FilmScanEngine \
  FilmScanAdjustmentBenchmark
```

The Python timing tests report best-of-several samples. Native benchmarks
report their own raw samples and median/p95 summaries; the opt-in renderer
burst gate also checks a 33 ms p95 target. Read each harness before comparing
results across workloads or hardware.

For the bounded photographic CPU point-correction probe:

```sh
python3 native/diagnostics/run-cpu-point-work-probe.py \
  --raw sample-raw/fuji400-fresh/DSCF2833.RAF \
  --output dist/cpu-point-work-next --mode full
```

The output directory must be fresh. `--preflight-only` checks setup without a
build, render or output; `--mode proxy` selects a 2048px source, and
`--cases blackAndWhite,calibrated-color` limits timed RAW cases. Every run also
hashes 72 untimed serial/banded branch cases. The runner builds an ordinary
production release, freezes the linked probe, and rejects changed source/input
or link artifacts. Timers cover warmed CPU correction, excluding decode,
bitmap packing, export, publication and screen presentation. It writes compact
JSON/logs rather than images. The [September 28 report](../docs/performance/cpu-point-work-2026-09-28.md)
records matched baseline/candidate hashes, timings and contention limits.

[Preview analysis](../docs/performance/preview-analysis.md) documents CPU
diagnostics and Darkroom benchmarks, including exact analysis/output hashes.
[40 MP export](../docs/performance/40mp-export.md) documents decode, packing,
writer, queue, cancellation, and physical-footprint measurements.
The [October 10 three-RAW JPEG study](../docs/performance/jpeg-three-export-2026-10-10.md)
documents frozen ordinary-release arms, five same-source baseline/candidate/baseline
rounds, exact JPEG hashes, and stage-timer boundaries. Its baseline already includes
the earlier parallel photographic conversion; use a fresh ignored output for a
new comparison.

The native opt-in switches below enable only their named measurements. Use
`-c release --no-parallel` and a matching `--filter`; setting one switch does not
run the other benchmarks. Tests in a benchmark-named file may still contain
ordinary default regressions.

| Environment switch | Swift test filter | Local input/output |
|---|---|---|
| `RUN_PERFORMANCE_TESTS=1` | `productionRendererBurstBenchmark` or `CPUPipelineBenchmarkTests` | Synthetic inputs; timing is printed. |
| `RUN_PREVIEW_ANALYSIS_BENCHMARKS=1` | `PreviewAnalysisPerformanceTests` | Synthetic inputs; optional `PREVIEW_ANALYSIS_CASE` selects a workload. |
| `RUN_NATURAL_BW_LOOKUP_BENCHMARK=1` | `NaturalMonochromeLookupTests` | Synthetic inputs; exact-output and timing checks. |
| `RUN_EDIT_REPLAY_BENCHMARK=1` | `benchmarkEditingWithPersistence` | Committed PNG plus temporary 640-entry settings store; prints `EDIT_REPLAY`. |
| `RUN_PREVIEW_STATISTICS_BENCHMARK=1` | `PreviewStatisticsPerformanceTests` | Requires `fuji400-fresh/DSCF2833.RAF`; compares repeated diagnostics with memoized results from the same full preview. Optional `FSC_STATISTICS_BENCHMARK_OUTPUT` saves raw timings and provenance. No images or exports written. |
| `RUN_WORK_REUSE_BENCHMARK=1` | `PerformanceFollowupBenchmarks` | Requires `fuji400-fresh/DSCF2833.RAF`; optional `WORK_REUSE_BENCHMARK_OUTPUT` saves JSON. |
| `RUN_APP_PATH_PERFORMANCE_TESTS=1` | `AppPathPerformanceTests` | Requires at least four RAFs; `APP_PATH_BENCHMARK_REPETITIONS` defaults to 3; optional `APP_PATH_BENCHMARK_OUTPUT` saves JSON. |
| `RUN_APP_PATH_EXPORT_PERFORMANCE_TESTS=1` | `AppPathExportPerformanceTests` | Requires at least four RAFs; expands to ten TIFF jobs; optional `APP_PATH_EXPORT_BENCHMARK_OUTPUT` saves JSON. |
| `RUN_PREVIEW_SCALE_BENCHMARK=1` | `PreviewScalePerformanceTests` | Requires `fuji400-fresh/DSCF2833.RAF`; optional `FSC_PREVIEW_SCALE_OUTPUT` saves JSON. |
| `RUN_PREVIEW_INTERACTION_BENCHMARK=1` | `PreviewInteractionPerformanceTests` | Requires `fuji400-fresh/DSCF2833.RAF`, a logged-in graphics session with Screen Recording access, and a fresh `FSC_PREVIEW_INTERACTION_OUTPUT` path. The wrapper command below sets the switch and output path. |
| `FSC_PREVIEW_BOUND_SWEEP=1` | `cameraScanPreviewBoundLatencySweep` | Runs only when the RAW corpus is available; prints bound/decode measurements. |

The work-reuse, app-path, export, and preview-scale measurements fail when
explicitly enabled without their required inputs. Create the parent directory
before using an output variable. Full command examples are in the
[native package guide](../native/README.md#benchmarks-and-diagnostics).
The representative roll workflow has its separate switch below.

`CameraScanByteIdentityTests.widerPreviewUnpackMatchesSerialOracle` compares
bounded camera-scan previews at one, eight and eleven actual unpack workers
using the named 11-strip Fuji fixture. It requires identical mosaic, demosaic,
processed, post-ISO and Swift pixel hashes; the complete RGB16 arrays also match.
The 16-worker override is bounded by strip count, while the normal default also
uses the machine's available CPU count. Full-resolution committed-hash and
serial-oracle checks remain in the same suite.

The app-path benchmark isolates and releases each model between phases. Its
cache-depth samples describe initial lookahead population, not filled cache
capacity. Separate retained-full cases measure revisits and viewport updates
with work counters, plus repeated saturated-cache switches with background-drain
timing and speculative-request counts. These are app-model publication timings
with 5 ms polling granularity; they do not measure native input or screen
presentation. Both full source/renderer/display sessions must fit the default
preview budget (typically at least 16 GiB RAM for two 40 MP scans); otherwise
the retained-full warmup can time out.

### Legacy corpus benchmark

The representative RAF corpus benchmark uses decoded 16-bit BGR arrays and
automatically selects the first root-relative frame in each top-level stock
folder. XMP grayscale metadata selects the B&W processing path.

```sh
.venv/bin/python tests/decode_sample_raw.py \
  --raw-dir sample-raw \
  --output-dir /tmp/film_scan_corpus

.venv/bin/python tests/benchmark_sample_raw.py \
  --decoded-dir /tmp/film_scan_corpus \
  --output-dir /tmp/film_scan_benchmark
```

The corpus manifest records film type, rotation, scene metadata, and selected
edit presets. Results include uncached and warm processing, render timings,
previews, and quality diagnostics; these do not imply a physically cold disk.

Compare native and RawPy decode performance and decoded-image quality:

```sh
swift build -c release \
  --package-path native/FilmScanEngine \
  --product FilmScanRawBenchmark

native/FilmScanEngine/.build/release/FilmScanRawBenchmark \
  sample-raw /tmp/film_scan_native_decode.json 3

.venv/bin/python tests/compare_raw_decode_benchmarks.py \
  --rawpy /tmp/film_scan_corpus/decode_results.json \
  --native /tmp/film_scan_native_decode.json \
  --output /tmp/film_scan_decode_comparison.json
```

See [Native RAW Compatibility Decode And Quality Benchmark](../docs/development/native-raw-benchmark.md)
for the eight-file compatibility-profile snapshot and its distinction from the
current app export profile.

## Color-Study And Paired-Reference Checks

The active paired Camera Raw, Pro Image, and segmented-skin studies have a
separate [color evaluation runbook](../docs/development/color-evaluation.md).
The current stages use canonical Film Bases, schema-2 public-control recipes,
and exact real-app parser/pixel checks. Follow the runbook's preflight, pinned
renderer, and fresh-output workflow, and preserve the user-preferred recipes
recorded there. Preflight success alone does not establish photographic or
end-to-end validation. Dated reports describe the engine,
inputs, and settings used for that run; they are not fresh validation after a
processing change.

The diagnostic Python tests are outside `tests/` and are not part of either
the legacy Python regression command or the current CI workflows. With the
runbook's Python dependencies installed, run them explicitly:

```sh
.venv/bin/python -m unittest discover -s native/diagnostics \
  -p 'test_color*.py' -v
```

This runs the runner and recipe-contract suites. They check content-hash
provenance, resume/retry behavior, rejection of old outputs without provenance,
exact-frame reference discovery, schema capture, public-control bounds,
preference defaults, and training-only recipe selection. They do not
decode RAWs, compile Swift, or measure rendered color.

The paired Swift reference tests normally use XMP orientation and crop metadata.
`native/FilmScanEngine/Tests/FilmScanEngineTests/Fixtures/paired_reference_orientations.json`
records three reviewed exceptions:
Lucky C200 DSCF5664, DSCF5702, and DSCF5705 have portrait JPEG pixels but landscape
XMP orientation. Their targets need one clockwise quarter turn to match sensor
coordinates. The September 18 registration artifacts report 697, 671, and 1,148
inliers respectively, with median residuals below 0.31 pixels, and inspection
confirms the orientation. The fixture binds each exception to its JPEG filename
and JPEG/XMP SHA-256 hashes; changed inputs fail for review. It does not guess
rotation from image dimensions or choose orientation by minimizing color error.
Unsupported metadata and out-of-bounds reference crops report the frame and
geometry involved. No color threshold or production rendering is changed.

### Photographic tone regression

`PhotographicToneTests` checks main-slider monotonicity at limits and combined
corners, endpoint behavior, highlight direction, headroom through curves,
calibrated inversion detail, shared crop analysis, and saved-version compatibility.
`LinearToneAdjustmentTests` explicitly exercises frozen version 1.
`LookRecipeAppTests` checks the undoable upgrade and endpoint fields through the
app parser. The full-RAW `AppModelTests` gesture check covers cropped GPU and
bounded legacy CPU interaction, followed by full-resolution refinement.

The comparator's current suite includes Whites/Blacks, alternate inversions and
cropped density-print transforms; its legacy suite pins version 1 explicitly.
See the [implementation report](../docs/development/photographic-tone-controls-2026-09-22.md).

### Ordinary slider response and native presentation

The [September 24 response study](../docs/development/slider-response-study-2026-09-24.md)
records small edits and combinations on six private photographs, fixed-region
color/texture metrics, explicit v2/v3 comparisons, and a native-window interaction
replay. `FocusedToneResponseTests` covers the opt-in v3 curve contract and actual
app correction parser; built-in looks remain v2. The current comparator includes a
separate v3 family. `PreviewRevisionMarkerTests` covers captured marker decoding,
and `PreviewInteractionPerformanceTests` normally runs only its small publication
trace check. The full native-window replay is explicitly opt-in.

The [preview latency follow-up](../docs/performance/slider-preview-latency-2026-09-24.md)
measures property-level UI updates and reuse of the edit proxy for a zoomed
overview. The existing full-RAW `AppModelTests` gesture case now also checks
that its visible detail matches the final complete raster within 1/255,
including a manual crop. Run the focused behavior checks with:

```sh
swift test --disable-sandbox -c release --package-path native/FilmScanEngine --no-parallel \
  --filter 'AppModelObservationTests|WheelEditingPerformanceTests|PreviewPublicationTests|ViewportRenderingTests|PreviewScrollViewTests|rawPreviewUpgradesAutomaticallyToFullResolution'
```

```sh
.venv/bin/python native/diagnostics/run-tone-response-study.py \
  --output dist/tone-response-next --metal
.venv/bin/python native/diagnostics/run-preview-interaction-study.py \
  --output dist/preview-interaction-next --repetitions 3 --events 120
.venv/bin/python -m unittest discover -s native/diagnostics -p 'test_*study.py'
```

For version 4 range separation and grading-point controls, use the explicit
paired profiles and a fresh output. The same runner now accepts version 4 and
measures Whites/Blacks and the three grading levels at ±0.25; the current
comparator includes individual and combined version-4 cases. The point controls
also round trip through the real correction parser in `GradingPointControlTests`.

```sh
.venv/bin/python native/diagnostics/run-tone-response-study.py \
  --output dist/tone-response-separated-next \
  --profiles native/diagnostics/tone-response-separated-profiles.json \
  --correction-documents --metal
```

Use fresh ignored output directories and normal macOS graphics access. The tone
runner needs the runbook's archived scans and preference snapshots; it rerenders
all five preferred looks and compares original PNG hashes. The interaction runner
needs `sample-raw/fuji400-fresh/DSCF2833.RAF` and existing Screen Recording access.
It captures only its diagnostic window and saves numeric timing/marker data, not
screen images. It measures compositor-observed revision updates, not physical
scan-out or native pointer latency. Both runners reject changed provenance. The
initial September 24 version-4 gallery is CPU-only because that standalone run
failed at its first Metal image. Later September 25 and October 2 checks completed
the bounded six-photo same-source CPU/Metal and full-resolution TIFF gates; see
[current verification](../docs/development/native-macos.md#verification-summary).
Require `--metal` to complete for a new photographic parity claim and preserve
any failures. The synthetic comparator and a CPU-only gallery do not establish
photographic Metal agreement.
Do not run builds, edits to native sources, or other performance studies alongside
them. See the report for paired profile and correction-document commands.

### Focused tone-control audit

The [September 22 audit](../docs/development/tone-controls-audit-2026-09-22.md)
records production ramp, photographic and render-latency probes. With the
runbook's private inputs and normal macOS graphics access, use a fresh output:

```sh
.venv/bin/python native/diagnostics/color-study.py doctor \
  --workflow paired --output dist/tone-audit-next
.venv/bin/python native/diagnostics/run-tone-control-audit.py \
  --output dist/tone-audit-next
.venv/bin/python native/diagnostics/summarize-tone-control-audit.py \
  dist/tone-audit-next
```

The runner builds current production objects and records source/input hashes.
The summary requires NumPy, OpenCV and Matplotlib. This standalone diagnostic
does not run in CI or endorse the observed clipping as desired behavior.

For the bounded C-41 performance question, run only the one-RAW timing cohort:

```sh
.venv/bin/python native/diagnostics/run-tone-control-audit.py \
  --timing-only --output dist/c41-refinement-next
```

This requires `sample-raw/fuji400-fresh/DSCF2833.RAF` and Metal access, with no
archived color-study inputs. It records first-use warmups and three warm samples
for each full/proxy, cropped/uncropped case; render-return and fresh RGBA8 bitmap
consumption are timed separately. Untimed passes capture Mach physical/peak,
resident/reusable bytes and require repeated output hashes to match. No disk
images are written; the executable stays in the ignored package build tree.
Missing Metal or failed renders fail this mode. There is no timing threshold,
CPU-parity claim, native-input or screen-presentation measurement. Use a fresh
output each time; the full audit summarizer does not accept timing-only output.
See the [collection report](../docs/performance/c41-refinement-discovery-2026-09-22.md).

`SharedPreviewBitmapTests` exercises the large complete-preview output writer on
unified-memory Metal devices. Four tests cover exact row/channel/orientation
output, buffer lifetime after source release and later renders, padded-row
accounting, AppKit wrapping, unsupported bounds and a >4 MP production render
with active curves/color compared to the original writer. Other devices skip
this suite and retain the original output path. See the
[controlled optimization comparison](../docs/performance/c41-shared-output-2026-09-22.md)
for exact real-RAW hashes, the consumer-time tradeoff, memory and app-path checks.

## Native Viewport And Roll Workflow

The default native suite exercises the actual AppKit scroll view through
draft/inspect/full-resolution size changes, panning, Fit, resize, and pinch
notifications. App-model comparison tests cover automatic crop, manual crop,
perspective, straightening, and their combination, including temporary editor
canvases and exact corrected-pixel restoration.
Source-editor regressions also exercise perspective edits, Reset, exposure,
and presets through Undo/Redo with Original comparison initially on and off.
They require the oriented original pixels to remain visible until the editor
closes, persisted settings to restore, and later history to reveal corrections
normally. GPU source previews use the existing 2/255 channel tolerance.

`CropAspectRatioTests` covers centered fitting, all eight handle anchors,
bounds, minimum sizes, landscape/portrait canvases, Fit/100%/zoomed drawing,
legacy settings, and preservation of destination geometry during look transfer.
`CropAspectRatioAppTests` exercises ratio changes and coalesced resize history,
uncropped editing, Free mode, per-file isolation, relaunch, and TIFF output
against CPU pixels after rotation, perspective, and straightening. Run these
with `--filter CropAspectRatio` and normal macOS graphics access.

Run the supplemental three-frame RAW workflow in a release build:

```sh
RUN_REPRESENTATIVE_ROLL_TESTS=1 \
CLANG_MODULE_CACHE_PATH=/tmp/film-scan-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/film-scan-swiftpm-cache \
swift test --disable-sandbox -c release \
  --package-path native/FilmScanEngine --no-parallel \
  --filter RepresentativeRollWorkflowTests
```

This requires `fuji400-fresh/DSCF2833.RAF`, `DSCF2851.RAF`, and `DSCF2856.RAF`
in the untracked `sample-raw/` corpus; explicitly enabling this workflow with
missing files fails the test. It applies an anchor look to selected
frames, checks an untouched frame and a reversible per-frame exception,
compares the full-resolution preview, exports in import order, changes settings
and re-exports through the retained decode, and restores persisted edits in a
new app model. Settings and TIFFs use a unique temporary directory; source
hashes must remain unchanged and all outputs are removed. The saved exception
explicitly chooses C-41, and look transfer must preserve its inversion identity
while exposure edits change both preview and exported pixels. This automated check
does not replace a hands-on assessment of focus, grain, gesture feel, or overlay
dragging in the packaged app.

`PerspectiveFramingAppTests`, `PerspectiveWarpTests`, and
`PreviewOverlayGeometryTests` cover optional perspective output ratios,
projective grid divisions, displacement-based corner dragging, screen-distance
snapping, one-source-pixel nudges in every orientation, single-step Reset Corners,
history/relaunch, and exact preview/TIFF pixels. The ratio describes the rectified
frame before downstream straightening or manual crop. Old crops retain automatic
edge-length sizing.

Run the six-photo, full-resolution version-4 tone/output gate explicitly:

```sh
RUN_PHOTOGRAPHIC_EXPORT_TESTS=1 \
PHOTOGRAPHIC_EXPORT_OUTPUT="$PWD/dist/photographic-exports-next" \
CLANG_MODULE_CACHE_PATH=/tmp/fsc-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/fsc-swiftpm-cache \
swift test --disable-sandbox -c release \
  --package-path native/FilmScanEngine --no-parallel \
  --filter PhotographicExportTests
```

Required RAWs: Fuji DSCF2833/2892, Pro Image DSCF5800/5809, and Phoenix
DSCF3079/3091 in their normal `sample-raw/` stock folders. Enabling the test with
missing files fails it. All range/grading controls are edited through the app;
full-source app/Metal previews must agree with the same-source CPU within 2/255.
Reopened app TIFFs must equal a fresh three-pass production CPU render exactly;
ImageIO/`sips` checks sRGB/depth/dimensions. The optional output directory retains
JSON parameters, medians, measurements and 900px review images; temporary full
TIFFs are removed. Use a fresh output per run. Preview-to-export differences from
one-pass versus three-pass decoding are reported separately, without a false
pixel-identity assertion across source tiers.

### Full-resolution edit scaling

The default real-RAW app-model test verifies that an active point-control
gesture on a selected full-sensor preview publishes a raster no larger than
2048px without changing the document's logical size. Ending the gesture must
then publish a full-size backing with the exact current parameters. Publication
ordering, source/selection/geometry rejection, and manual-crop GPU tests remain
separate default gates.

Run the opt-in release probe for raw timing and Mach physical-footprint samples:

```sh
RUN_PREVIEW_SCALE_BENCHMARK=1 \
FSC_PREVIEW_SCALE_OUTPUT=/tmp/fsc-preview-scale.json \
CLANG_MODULE_CACHE_PATH=/tmp/fsc-preview-scale-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/fsc-preview-scale-swift \
swift test --disable-sandbox -c release \
  --package-path native/FilmScanEngine --jobs 2 --no-parallel \
  --filter PreviewScalePerformanceTests
```

It uses `fuji400-fresh/DSCF2833.RAF`, alternates three consumed renders with
and without a fixed crop at each app tier, and also measures the exact 2048px
full-session proxy. Three samples are reported as a median and maximum, not a
p95. The probe does not measure native input or screen presentation. See the
[recorded measurement](../docs/performance/preview-scale-2026-09-14.md).

## Repaired RAW Output Contract

The real-RAW dust gate checks one named Fuji scan with manual and automatic mask
repairs, framing, schema-3 persistence/relaunch, Original/repair visibility, exact
reopened production-CPU TIFF pixels, independent 16-bit sRGB tags, and unchanged
input bytes. Deliberately marked areas establish workflow/output correctness;
they do not establish detection accuracy or photographic healing quality.

```sh
RUN_RAW_DUST_EXPORT_TESTS=1 \
RAW_DUST_EXPORT_OUTPUT="$PWD/dist/raw-dust-export-next" \
swift test --disable-sandbox -c release --package-path native/FilmScanEngine \
  --no-parallel --filter RawDustExportTests
```

Required input: `sample-raw/fuji400-fresh/DSCF2833.RAF`. An explicitly enabled
missing-input run fails. The optional output directory must be fresh; it retains
compact reports/settings and 900px review PNGs, while temporary full TIFFs are
removed. Run with normal macOS graphics access.

## Sustained Preview And Cached-Revisit Measurement

The sustained navigation gate uses Fuji DSCF2833/2851/2856 and a two-session cache,
checks full corrected bitmap identity through eviction/revisits, new edits,
Original, simulated app memory pressure, Close All, and verified model release.
It reports work counters, charged preview bytes, and independent Mach physical
and peak footprint samples. These are AppModel publication timings, not native
input/screen latency, OS-wide pressure, thermal cost, or a before/after gain.

```sh
RUN_SUSTAINED_PREVIEW_TESTS=1 \
SUSTAINED_PREVIEW_LOOPS=4 \
SUSTAINED_PREVIEW_OUTPUT="$PWD/dist/sustained-preview-next.json" \
swift test --disable-sandbox -c release --package-path native/FilmScanEngine \
  --no-parallel --filter SustainedPreviewPerformanceTests
```

The output filename must be fresh; without one, a unique temporary JSON is used.
Loops are bounded to 2–8, with four by default. The test retains no images.
Eviction in this workload is count-driven; it does not saturate the normal byte
budget on the development Mac. First publication and full-source/statistics
settling are separate model events.

For a byte-limit collection, `SUSTAINED_PREVIEW_COHORT=fuji-eight-cpu` uses
DSCF2833/2851/2856/2865/2873/2881/2888/2892 from `fuji400-fresh/`, depth eight,
and identical version-4 C-41 perspective/2° straighten settings. This mode requires
the normal 3 GiB preview budget (at least 24 GiB physical RAM). Eight distinct RAW
hashes and previously warmed full-session loss below depth eight distinguish it
from the count-limit workload. Selected full-session presence and charged bytes
within budget are asserted. A monotonic pressure-handler counter must remain
zero through navigation and the later correctness checks, up to the deliberate
app-pressure call; this mode rejects a collection contaminated by an earlier
real or simulated cache-drop handler. Each state records that count. Aggregate
admission reservations and cancelled or completed native decode calls are not
exposed by the existing counters.

```sh
RUN_SUSTAINED_PREVIEW_TESTS=1 \
SUSTAINED_PREVIEW_COHORT=fuji-eight-cpu \
SUSTAINED_PREVIEW_LOOPS=4 \
SUSTAINED_PREVIEW_OUTPUT="$PWD/dist/sustained-byte-capacity-next.json" \
swift test --skip-build --disable-sandbox -c release \
  --package-path native/FilmScanEngine --no-parallel \
  --filter SustainedPreviewPerformanceTests
```

Build the frozen source first. The report records cohort, frame paths, complete
initial settings, source/logical/bitmap dimensions, full versus partial cache
tiers, physical footprint, pressure recovery and model release. A collection
alone establishes capacity behavior, not a latency or memory improvement.

The cached-revisit gate compares three alternating-order pairs of identical
full-source CPU exposure edits on Fuji DSCF2833, with DSCF2851 as the cached
navigation neighbour. Explicit version-4 C-41 perspective and straightening force
the CPU route. Every timed edit requires one correction, no accepted full-source
decode, and exact bitmap/parameter agreement with a later production CPU oracle.

```sh
RUN_CACHED_REVISIT_EDIT_TESTS=1 \
CACHED_REVISIT_EDIT_OUTPUT="$PWD/dist/cached-revisit-edit-next.json" \
swift test --disable-sandbox -c release --package-path native/FilmScanEngine \
  --no-parallel --filter CachedRevisitPointEditPerformanceTests
```

Use a fresh JSON filename and a frozen build/source manifest for each arm. The
report's runtime executable fingerprint can be the Swift Testing helper; retain
the actual test-bundle hash separately. Measurements describe model publication,
worker rendering and process footprint. The Close All footprint includes local
source references kept for pixel guards; the verified-model-release sample is
taken after those references leave scope. Peak footprint includes untimed hashing
and the oracle. These small paired runs do not establish general capacity,
screen latency or energy gains.

The detailed-gesture gate asks whether that preparation benefit carries into the
first 100% CPU viewport edit after a cached revisit. It uses the same two RAWs and
C-41 geometry, a 1200×800 visible region, 1344×960 exact detail and a 1024px
bounded overview. Three alternating warm/revisit pairs time one exposure setter
and the later full-resolution release refinement separately. Every arm starts
from the same untimed viewport warmup and full EV 0 state. Trace/counter guards
require full-source CPU viewport work, one accepted correction and no full decode
per phase. Fresh CPU full/viewport oracles run after all timed arms.

```sh
RUN_DETAILED_CACHED_REVISIT_TESTS=1 \
DETAILED_CACHED_REVISIT_OUTPUT="$PWD/dist/detailed-cached-revisit-next.json" \
swift test --skip-build --disable-sandbox -c release \
  --package-path native/FilmScanEngine --no-parallel \
  --filter DetailedCachedRevisitPerformanceTests
```

Build the frozen package first. `DETAILED_CACHED_REVISIT_SAMPLE_ROOT` optionally
sets an explicit corpus root for an isolated baseline package. Use an identical
harness and inputs across comparison builds, with external test-bundle/source
fingerprints. The same physical-memory, release and screen-presentation limits
above apply. This gate measures a first detailed publication and full refinement;
it does not measure a continuous drag, Fit/proxy work or photographic quality.

## Independent-Viewer Output Contract

Contact-sheet tests exercise the actual app export path with selected/all
scans, edits changed after the export snapshot, active comparison/crop tools,
case-insensitive filename collisions, cancellation, failure/retry, and enabled
stack consolidation. PDFKit checks filenames and pagination at 12/13/25 scans;
Core Graphics checks corrected tile pixels. A local three-RAF case verifies
bounded preview export without populating the full-resolution export cache.

To retain the three-RAW PDF and a pagination fixture for file-based visual review:

```sh
CONTACT_SHEET_QA_OUTPUT=/tmp/fsc-contact-sheet-qa/contact-sheet.pdf \
CLANG_MODULE_CACHE_PATH=/tmp/film-scan-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/film-scan-swiftpm-cache \
swift test --disable-sandbox -c release --package-path native/FilmScanEngine \
  --no-parallel --filter ContactSheetExportTests
```

The RAW case requires `fuji400-fresh/DSCF2833.RAF`,
`cinestill800t/DSCF3247.RAF`, and `shanghaigp3/DSCF3200.RAF`; it explicitly
skips when those local files are missing. Without the output environment
variable, all generated PDFs are removed after testing.

App-path TIFF, JPEG, and PNG exports are reopened by ImageIO and `/usr/bin/sips`
as a second macOS reader. The check requires named sRGB, baked orientation
(tag 1), honest bit depth (16/8/16), and dimensions that match the on-canvas
geometry plus export frame. Processed DNG is inspected from TIFF/DNG tags,
including UniqueCameraModel `Film Scan Converter Processed RGB` and
output-referred ColorimetricInterpretation; it is not required to open as a
camera RAW in Preview. The opt-in three-frame RAW roll applies the same
named-sRGB TIFF inspection to its exported files.

```sh
swift test --disable-sandbox --package-path native/FilmScanEngine --no-parallel \
  --filter IndependentViewerOutputTests
```
