# Native macOS Development Status

This page owns current implementation status, verification, and limitations.
[Features](../features.md) describes the user tools; the
[roadmap](../improvements/MacOS-Native-Roadmap.md) owns priority.

**Source status reviewed September 25, 2026 (PDT). The latest complete native
suite includes version-4 tone controls, preview latency work, deferred look
initialization, single-worker rendering, and improved perspective framing.**
The implementation descriptions include local working-tree
changes beyond the published beta. Verification below is dated evidence, not an
automatic claim about every later edit. Local RAW tests depend on the untracked
`sample-raw/` corpus; CI cannot reproduce those cases without it.

## Release Position

The native Swift/SwiftUI app is the primary product. The latest downloadable
build is [0.2.0 Beta 3](https://github.com/athoma28/Film-Scan-Converter/releases/tag/v0.2.0-beta.3),
an ad-hoc-signed Apple Silicon build for macOS 14 or later. Later checkout
changes and local packages do not establish a newer public release.

The packager assembles and validates self-contained app/ZIP artifacts and
supports Developer ID signing and notarization. A notarized distribution,
no-bypass Gatekeeper check, and installation on an independent supported Mac
have not been demonstrated. See the [release runbook](native-release.md).

## Current Application

| Area | Implemented behavior |
|---|---|
| Import and browsing | Standard images use a 1000px ImageIO preview. Camera RAW uses a colour-accurate draft, selected-file inspect and full-sensor 1-pass previews, and memory-bounded full-sensor neighbour lookahead. Completed decoded/corrected previews survive navigation; settled panning submits no corrections. Supported whole-image point gestures on a selected full RAW can use a 2048px interaction source followed by exact full-source refinement; detailed viewport requests use the full source. Sidebar thumbnails are separate. |
| Inspector | Develop, Geometry, Calibrate, and Export pages; full-output dimensions in the header. Develop contains Film Base, Presets, Tone & Light, and Color & Balance. |
| Processing | Film bases Color C-41, cyan-mask, B&W, Slide, and Original; factory and user looks as public slider snapshots; tone, color, curves, wheels, dye crossover, and optional measured-density processing. B&W overall tone curves work on CPU and GPU. |
| Geometry | Auto Frame, freeform/fixed-ratio manual crop, two-point straighten, four-corner perspective with known frame ratios, projective grid and pixel nudges, rotation/flip, frame and aspect padding. Shared dimension prediction and preview/export geometry. Changing upstream geometry invalidates the dependent manual canvas crop; clearing that manual crop retains upstream geometry. |
| Viewport | Fit, pan, pinch, zoom steps, and 100% current-preview pixels. Original comparison and source-resolution upgrades preserve the viewed region. Overlays convert gesture coordinates using native magnification. Selection changes fit the new image. |
| Edits and rolls | Per-file persisted settings; session-local undo/redo with gesture coalescing; presets, clipboard transfer, selected/all look application, navigation in sidebar order, and export-state sidebar markers. Post-Beta-2 source adds session-local up/down reordering. |
| Stacks | Opt-in adjacent repeated captures, translation alignment, Auto/Noise/HDR modes, bounded-to-full-resolution preview, and one export under the first capture's name/settings. Original captures merge in row bands through temporary disk storage; failures retain a usable preview and report status. |
| Export | Sequential full-resolution TIFF/JPEG/PNG/processed-RGB DNG, collision-safe naming, stage-boundary cancellation, and cleanup. The selected RAW may retain its last three-pass decode for settings-only re-export. |
| Contact sheets | Selected/all PDF export with 12 corrected previews per Letter-size page, filenames, sidebar order, and one merged tile per enabled stack. Edits are captured at start; Original comparison and open crop editors do not alter the output. Progress, cancellation, staged commit, and collision-safe names share the app export workflow. |
| Live camera | AVFoundation preview for devices exposed by macOS, with invert/exposure/saturation. Vendor-specific tethering is not implemented. |

Film Base selects the inversion contract independently of the chosen look. The
factory looks are Clean Invert, Soft People, Punchy Print, Warm, Cool, Foliage,
Night Lift, B&W Print, and B&W Soft. They and saved presets capture public Develop
controls; applying one preserves film base, inversion IDs, calibration, and
geometry. Reset Adjustments preserves those same per-frame choices. These are
creative starting points, not validated named-stock calibrations. The former
adaptive/Kodachrome-like look implementation has been removed. Existing Natural
curves and Darkroom profile code retain their engine contracts and recorded
provenance, rather than describing the current preset menu.

## Processing And Memory Contracts

- Swift owns 16-bit BGR buffers returned through the narrow LibRaw C/C++ bridge.
  The CPU pipeline is the deterministic export/reference authority.
- Camera-scan export uses the frozen LibRaw 0.21.4 integer three-pass X-Trans
  oracle. Independent X-Trans wavefront diagonals use at most eight workers.
  Fuji compressed strips use up to 16 workers when a decode runs alone and at
  most eight while another camera-scan decode is active. `LIBRAW_FORCE_OPENMP`
  stays off because its overlapping
  X-Trans tiles fail the exact-output contract. This is not live RawTherapee parity.
- The [X-T5 compatibility adapter](raw-decode-compatibility.md) preserves the
  established uncropped source geometry and color conversion under LibRaw
  0.22.2. The newer library's active-area and matrix defaults otherwise change
  saved edits and frozen pixels. Other cameras and layouts retain LibRaw defaults.
- RAW preview bounds are 640 draft, 4000 inspect, and 3200 initial lookahead;
  actual dimensions follow CFA binning. Completed full-sensor 1-pass previews
  remain cached across selections, and up to two neighbours can warm full detail.
  The independent selected-file export decode still drops on selection change.
  See [preview architecture](realtime-preview-plan.md).
- The preview cache defaults to eight sessions, bounded by one eighth of physical
  RAM up to 3 GiB. Sources, analysis, RGB16/RGBA16 interaction proxies, renderer
  backing, and completed display rasters count toward the budget. Display space
  is reserved before speculation. Only a selected image that exceeds the budget
  by itself is exempt. System memory pressure releases unselected entries and
  suspends background work. The current inspector has no cache-size control.
- RAW work uses at most two concurrent decodes on machines with at least 16 GiB
  RAM, and one on smaller machines. At most one worker is speculative; export
  preempts it. Editing gestures keep useful prefetch progress. Render scheduling
  still retains only one active and one latest pending request.
- Stacks decode originals sequentially and use temporary disk space of roughly
  two bytes per channel per pixel per capture. Temporary files are removed on
  success, failure, and cancellation. A loaded flat field prevents stacking.
- CPU clipping diagnostics sample at most 65,536 pixels without full-frame
  Double expansion. Darkroom analysis shares sorted channel percentiles and
  retains pixel/chroma pairs during neutral-axis selection.
- Settled previews retain a complete corrected raster; pan/zoom changes the
  viewport without new correction or statistics work. Active edits can use a
  viewport region plus overview before exact full-source refinement. CPU
  preparation reuses geometry and analysis; asynchronous statistics are bound
  to the published revision. The September 16 region-rendering timings describe
  the earlier implementation, not the current retained-raster navigation path.
- Metal handles supported still corrections, including warm-hue recovery.
  Measured-density processing, perspective/straighten, cropped density-print
  color negatives, near-flat density-print inputs (any channel log span below
  0.001), and other analysis-dependent cases retain CPU fallbacks.
  In particular, cropped C-41 editing does not demonstrate GPU-path performance.
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

The table records the source state and workload checked on each date. Full-suite
passes do not rerun skipped performance studies or prove photographic acceptance.
The standalone comparator now includes current Film Bases, all factory recipes
across editable bases, public control endpoints, and combined grading. Explicit
flat-density CPU routes are counted separately from GPU comparisons. This is
synthetic coverage, not complete photographic or export acceptance.

### September 25 UTC: workflow, color, output and perspective

The [follow-through report](roadmap-follow-through-2026-09-25.md) records the
repaired deferred-look/classification, detached-worker overlap and direct-full
RAW request paths, the public-recipe study migration, and improved perspective
framing. Artifact dates use UTC; this run occurred September 24 PDT.

Fresh final-source verification on the M4 Pro/macOS 15.7.9/Swift 6.1.2:

- Complete release suite: **739 tests, 17 opt-in skips, zero issues**, 270.891 s.
  The opt-in roll and six-photo export checks were run separately below.
- Focused geometry: **51 tests passed**, including app history, persistence,
  rotated ratios and exact preview/TIFF pixels. Focused workflow: **16 passed**.
- Final comparator: **4,608 cases**, 4,164 GPU comparisons within 2/255 plus
  444 verified CPU routes; zero render failures.
- All **24 diagnostic Python tests**, strict formatting of the 20 changed Swift
  files, and whitespace checks passed.
- Complete cumulative color study: **40 registered pairs**, two incomplete pairs
  reported, **254 exact app-applied recipe/pixel checks**, **13 named presets**,
  **five exact frozen preference hashes**, and **11 full-resolution study JPEGs**.
  After the additive geometry changes, all 254 parser/pixel checks and all five
  preference renders passed again through the final engine.
- Photographic tone study: **204 same-source CPU/Metal cases** over six photos,
  versions 2/4 and 17 variants; maximum difference **1/255**, zero failures.
- Explicit full-resolution tone/export test: all **six 7752×5184 photos** passed
  full-source app/Metal versus CPU at 1/255, exact reopened 16-bit TIFF versus
  fresh three-pass CPU output, and independent sRGB/depth/dimension inspection.
- Explicit three-frame Fuji roll workflow passed transfer, exceptions,
  comparison, three reopened TIFFs, ordered export, retained-decode reuse and
  relaunch; source hashes were unchanged. Current Lucky native renders and its
  five-scan unpaired-reference gallery also completed.

The five selected full-resolution skin recipes are a subset of the thirteen
published candidates. Whole-stock accuracy is not established; individual skin
regions, non-skin controls and photo-transfer failures remain in the report.
The one-pass preview and three-pass export have different decode contracts:
whole-frame mean differences were 0.104–0.461 display levels, with maxima
98–250; the 1/255 comparison above applies only to the **same source**.
Existing looks and defaults are unchanged. Hands-on packaged-app gesture/viewer
judgment remains separate. Real independent stack captures are pending and
notarized distribution is last priority, both by owner direction.

### September 24 slider-to-preview latency

The [latency follow-up](../performance/slider-preview-latency-2026-09-24.md) replaces
window-wide model notifications with property-level Observation and separate
view bodies. Preview availability updates independently of raster identity.
Zoomed full-RAW GPU gestures reuse the retained edit proxy for their background
overview; visible detail and complete refinement still use the full source.
Processing math, defaults, saved formats, and export rendering are unchanged.

A fresh three-repetition native-window replay on the M4 Pro, macOS 15.7.9,
Swift 6.1.2, and full 7752×5184 Fuji DSCF2833 RAW measures median setter-to-capture
delay of **94.00 → 52.94 ms at Fit** and **126.12 → 55.87 ms at 100%**. These are
medians of per-case medians, including capture delivery. Distinct composited
revisions rise from 17.17–30.03 to 44.72–48.32/s at Fit and from 15.15–19.67 to
42.57–44.49/s at 100%. Final full-raster capture still takes 218.63–233.74 ms
after release. The report preserves baseline variability, a separate UI-only
run, memory samples, input lateness, marker exclusions, and measurement limits.

Fresh release verification passes **728 tests, 16 opt-in skips, zero issues**
(392.732 seconds), with local RAW inputs and normal graphics access. The native
interaction and preview-scale benchmarks were run separately. The focused
15-test run verifies observation isolation, undo, stale publication rejection,
viewport transitions, and manually cropped real-RAW detail agreement with the
final raster within 1/255. Strict changed-file Swift formatting and whitespace
checks pass. Source and app/test binary hashes remain identical to the measured
final run. Evidence is in ignored `dist/preview-latency-*-2026-09-24/`.

The standalone comparator, photographic preference galleries, representative-roll
exports, native pointer replay, energy, and packaged release were not rerun.
This is a source/build improvement beyond the published beta, with unchanged
processing math; the replay does not measure physical screen scan-out.

### September 24 code cleanup and complete regression

This pass starts from `fc63454` plus the existing uncommitted Film Base,
LookRecipe, retained-preview, and version-4 tone work. `PreviewSessionCache` now
owns decoded sessions, corrected rasters, LRU order, and memory admission
together. Public photo setters share finite-value validation and range clamping;
optional foliage-recovery decoding uses the same finite-number check as other
adjustments. Unused setters and obsolete test-only color/wheel entry points were
removed while legacy JSON migration remains covered by engine tests. Rendering
math, factory recipes, and the preference ledger were not changed.

Tests now exercise the current UI setter paths, gate queued decode cancellation
explicitly, and cover all 1,024 independent tone/grading endpoint combinations
instead of coupling exposure, brightness, and contrast to other controls. Added
regressions cover cache admission and stale-render rejection, invalid edits,
slider bounds, and undo across tone-version promotion. The
[test guide](../../tests/README.md#current-default-coverage) lists focused commands.

Fresh verification used Swift 6.1.2 on macOS 15.7.9 (24G830), Apple M4 Pro
(Mac16,7), 48 GiB RAM, with the local RAW corpus and normal graphics access:

- `swift test --disable-sandbox -c release --package-path native/FilmScanEngine
  --no-parallel`: **727 tests, 14 opt-in skips, zero issues**, 374.697 seconds.
  LibRaw decoding accounted for 225.605 seconds; this is not a performance comparison.
- The standalone comparator passed **4,608/4,608** cases: 4,164 GPU comparisons
  within 2/255 and 444 verified CPU routes, with no render failures.
- C/C++ RAW compatibility checks, all **19** diagnostic Python tests, and strict
  package-wide Swift formatting passed. Formatting cleanup resolved 117 existing
  warnings across six recent source/test files.
- The standalone release build of `FilmScanConverterMac` passed (39.33 seconds).
- All **five** frozen preference PNGs were freshly rendered through the production
  engine from the archived scans and historical medians and matched the ledger
  hashes exactly. This checks those bounded historical appearances, not new
  classification, stock fitting, or full-resolution export acceptance.

Logs, source/fixture hashes, preference input provenance, and fresh preference
renders are retained locally in ignored `dist/clean-code-pass-2026-09-24/`.
The initial restricted run could not exercise Metal/AppKit correctly and did
not complete; the graphics-enabled full run above supersedes it. Opt-in
performance measurements, compositor interaction, representative-roll export,
and packaged release validation were not run during this cleanup.

### September 24 separated tone ranges and grading levels

[The version-4 response study](tone-range-separation-2026-09-24.md) records the
new native Develop behavior: broad Highlights/Shadows, focused Whites/Blacks
that retain output endpoints, and Shadow Floor/Midtone Level/Highlight Ceiling
under the color wheels. Saved versions 1–3 keep their rendering until the user
edits a newly responsive control or explicitly upgrades version 1; factory
looks remain pinned to version 2. The six-frame CPU study has 204 fresh renders,
no exclusions and five exact preferred-look hash matches. Its tonal fifths and
individual skin, foliage, window and path regions show distinct responses at
±0.25. Focused release tests pass 33/33; the synthetic native comparator passes
4,608/4,608 with 4,164 GPU comparisons within 2/255 and no failures. The
standalone photographic study's Metal path fails at its first image on this
host, so photographic Metal parity and full-resolution export remain unverified.
That study ended without a complete-suite result; the later cleanup verification
above covers the current version-4 source.

### September 24 ordinary slider response and native interaction

[The response study](slider-response-study-2026-09-24.md) adds reproducible small
photographic edits/combinations and compositor-observed native-window replay.
Making the Develop inspector lazy raises observed Fit updates from 28.19–29.54/s
to 37.76–39.35/s in sequential three-repetition runs; 100% reaches 23.24–26.37/s.
The report separates worker time, main-actor delays and capture delivery, records
memory/failures/provenance, and does not claim physical pointer-to-screen latency.
The 40/s target remains unmet.

Explicit tone-version-3 trials focus Highlights/Shadows response toward their
selected tails; defaults, factory looks and existing upgrades remain version 2.
The ordinary Shadows +0.25 / Contrast +0.1 combination lifts the darkest fifth
in all six tested photographs, versus darkening four under v2. All 240 paired
CPU/Metal renders pass within 1/255, all five preferred PNGs match, and all 120
overlapping v2 renders remain byte-identical. Color/local-contrast tradeoffs and
fixed-range limitations remain in the gallery; v3 is a review candidate.

The native release suite reports 711 tests with 14 opt-in skips, zero issues
(269.068s); the separately run compositor study and all 4,398 comparator cases
pass their evidence/parity gates. Python diagnostics pass 18 tests. Full-resolution
v3 export agreement/cost and photographic acceptance remain unverified.

### September 23 editing and retained-image work reuse

[The follow-up report](../performance/edit-switch-work-reuse-2026-09-23.md)
records memoized per-raster diagnostics, statistics-only completion for already
complete edits, and one combined hue/strength update per color-wheel event.
Focused release verification passed 31 tests, including real-RAW GPU/CPU proxy
refinement, publication ordering, persistence, and wheel undo/redo. The separate
statistics probe and app-path benchmark each passed three tests. Six retained
full-preview switches plus 1,000 viewport updates added zero decodes, corrections,
or statistics computations. Retained model publication p50 was 6.86 ms near the
5 ms polling floor; this is not a measured screen-latency improvement. The
report preserves variable uncached timings, physical footprint, initial test
failures and corrections, provenance, and unrun checks. No processing defaults
or color math changed; this was not a complete native-suite rerun.

### September 22 RAW draft unpack optimization

The [compressed-strip follow-up](../performance/raw-preview-unpack-2026-09-22.md)
reduced median draft decode latency by 15.2–30.3% across three X-T5 files in a
frozen-binary M4 Pro comparison. Unpack permits more independent strips when
alone and caps newly starting work at eight workers when another camera-scan
decode is active. All 176 RAW output hashes agree, final identity/scheduler tests
pass (13), the 4,132-case comparator passes, and five fresh preferred CPU renders
match. Four app-path runs pass retained-work and release guards; the report
records their variable latencies, memory, and the rejected unrestricted variant's
navigation regression. This is a draft-decode gain, not a 15% full-sensor,
export or app-wide claim.

### September 22 full-preview output optimization

The [shared output implementation](../performance/c41-shared-output-2026-09-22.md)
reduced median full-resolution C-41 render-and-consume time from 107.92 to
46.22 ms (57.2%) in eight counterbalanced processes on the M4 Pro. Large complete
rasters use synchronously completed shared Metal buffers; smaller/scaled/viewport
requests retain their existing path. All 12 case/EV hashes match, all five
preferred CPU look renders match, the 4,132-case comparator passes, and focused
release tests plus the real app retention/release guard pass. Peak probe footprint
fell while post-release footprint rose; the report records both. This is one
40 MP photograph's render path, not native input-to-screen or app-wide latency.

### September 22 optimization target collection

The [bounded C-41 refinement collection](../performance/c41-refinement-discovery-2026-09-22.md)
completed two sequential one-RAW runs. Uncropped full-resolution render medians
were 88.98 / 92.69 ms, followed by 16.21 / 16.08 ms diagnostic bitmap consumption;
process peak physical footprint was 810.85 / 813.28 MiB. All 12 case/EV pixel
hashes match between processes. A fresh full comparator passed 4,132/4,132 cases
(3,796 GPU comparisons within 2/255, 336 explicit CPU routes, zero render failures).
The diagnostic timing-only mode and documentation are the only source changes
in this collection. This is target discovery, not a measured speedup or
input-to-screen result; the full native suite and photographic studies were not
rerun. The report records provenance, all raw samples, exclusions and next work.

### September 22 photographic tone fix

The [photographic tone implementation](photographic-tone-controls-2026-09-22.md)
replaces the audited operators for new edits, keeps float precision through
curves, and enables cropped density-print GPU previews. Legacy edits retain their
version until explicitly upgraded. All five preferred-look hashes match fresh
renders. The expanded 4,132-case CPU/Metal comparator and final full native release suite
(687 tests, zero issues, 396.198 s) pass; the implementation report records
photograph, full-resolution and native app checks.

### September 22 tone-control audit

The [tone-control audit](tone-controls-audit-2026-09-22.md) measured 16 production
grayscale-ramp variants, two targeted counterexamples, 42 fresh CPU renders of
three archived 900px scans, and three direct render-performance cases. It
confirms brightness-induced shadow clipping, contrast endpoint compression,
early display clipping, highlight tone reversal, and the cropped density-print
CPU latency cliff. On the M4 Pro, the final one-pass-preview probe recorded
10.21 ms median for the uncropped 2048px GPU drag proxy and 2068.10 ms for a
manually cropped default color-negative CPU edit (three warm samples each).
These are render-and-consume timings, not native event-to-screen measurements.

Release build, diagnostic execution and artifact consistency checks completed.
The audit changes no production code or defaults. It does not rerun the full
native suite, ACR fitting, full-resolution image exports, preference checkpoints,
or photographic CPU/Metal comparisons. Private inputs and generated artifacts
remain under ignored `sample-raw/` and `dist/`; exact provenance, exclusions and
reproduction commands are linked in the report.

### September 20 edit preservation and settings recovery

The working tree based on `c4ad5ba` now removes batch-edited destinations from
automatic reclassification. Changing the anchor's Film Base previously replaced
their transferred controls and film base with a newly guessed default recipe.
Apply Selected and Apply All preserve those edits; undo/redo also restores the
destination's classification eligibility. A synthetic two-frame app regression
reproduced eight assertion failures before the repair.

If the app cannot read `PerFileSettings.json`, its initially empty persistence
state no longer overwrites that document on the next edit. Saves retry reading
the existing file and fail while it is malformed or unsupported. After repair or
removal, saving can resume; recovered unrelated files survive every later save,
and the session's values and edited markers win for matching files. The extra
read/merge is limited to sessions whose initial load failed. The original
malformed and version-99 fixtures were both overwritten before this repair.

Fresh verification uses arm64 macOS 15.7.9, Swift 6.1.2, and LibRaw 0.22.2 with
normal graphics access. All **23 focused tests passed**, including byte-for-byte
file preservation, repaired/removed-library retry, repeated recovery writes,
edited-marker restoration, batch transfer, preset migration, and look undo/redo.
The complete release suite with `RUN_REPRESENTATIVE_ROLL_TESTS=1` passed in
**477.056 seconds: 677 tests reported, 664 passing records, 13 opt-in skips,
zero issues**. Available RAW references and the three-frame roll's preview,
look transfer, export/re-export, and relaunch checks ran. The release build also
linked the native app. This duration is regression-run evidence, not an
app-performance measurement.
Strict formatting of the four changed Swift files and `git diff --check` passed.
Local logs and a source manifest are in ignored
`dist/workflow-correctness-2026-09-20/`.

The repair does not change processing math or factory defaults. It does not
establish photographic acceptance or repair the separate unclassified-destination
and preview-scheduling candidates listed in the roadmap. Packaging, manual UI
inspection, and fresh color studies were not performed.
The standalone comparator and performance benchmarks were not rerun; neither
processing math nor rendering code changed. The strict MkDocs build was not
rerun because MkDocs is unavailable in the current virtual environment.

### September 20 current-workflow preview parity

A fresh release comparator run on the working tree based on `c4ad5ba` used an
Apple M4 Pro MacBook Pro (48 GB RAM), macOS 15.7.9, Swift 6.1.2 and LibRaw 0.22.2.
This includes the existing Film Base / LookRecipe and warm-hue changes, plus the
new source-dependent density precision guard and comparison coverage.

The expanded current matrix exposed up to **30/255** RGB error on a constant
midtone negative with maximum Highlights. Float log-density cancellation divided
by an almost-zero analyzed range caused the disagreement. Density-print inputs
with any channel log span below **0.001** now use the app's existing Double CPU
fallback. Original bypasses the check. CPU processing, factory recipes and color
defaults are unchanged by this repair; ordinary-density GPU arithmetic is also
unchanged. Flat-frame editing may incur full-source CPU latency; no speed or
memory improvement is claimed.

The final default comparator checked **3,901/3,901 cases**: **3,613 GPU comparisons**
within **2/255**, **288 explicitly verified CPU routes**, and **zero render failures**.
The preserved legacy grid contributes 2,725 GPU comparisons. Current cases add
five film bases, all nine recipes across four editable bases, public slider
endpoints, density cleanup/separation, six dye-crossover axes, combined
curves/wheels, and oriented Original comparison. Seven synthetic images include
flat extremes, a full chromatic cube, and odd-sized rows. Unexpected fallback,
missing renderers, invalid layouts, dimension mismatches and incomplete cohorts
fail the gate; CPU exclusions are not reported as GPU parity.

`FilmBaseRecipePreviewTests` additionally covers chromatic constant inputs,
one-code ranges, and isolated bright/color center outliers, plus app publication
of full-size CPU pixels during an edit and Original comparison. Raw local logs
and a source manifest are under ignored `dist/preview-parity-2026-09-20/`.
The complete release suite passed in **277.426 seconds: 673 tests reported,
659 passing records, 14 opt-in skips, zero issues**. All six new test records passed;
the local RAW tests ran. The representative roll and opt-in performance runs were
not enabled. The release test build also built the app and package executables.
Strict formatting of the four touched Swift files and `git diff --check` passed.
No package, manual UI check, or fresh color-study run was produced.

Synthetic parity does not refresh the color-study preference checkpoints or
establish photographic, full-resolution export, or independent-Mac acceptance.

### September 19 retained-preview performance follow-up

Fresh release measurements use the current working tree based on `c4ad5ba` on
an Apple M4 Pro (48 GiB RAM), macOS 15.7.9, Swift 6.1.2, and LibRaw 0.22.2.
The [performance report](../performance/retained-preview-2026-09-19.md) records
the ten-file local RAF cohort, raw samples, source/input hashes, and limitations.

Before submitting speculative preview work, the app now rejects candidates that
cannot fit the retained cache's count or exhausted byte budget. A two-file full
cache previously decoded and discarded the third neighbour on each revisit.
Across three matched revisits, unused submissions fell from **1/1/1 to 0/0/0**,
and median background drain fell from **1,062.01 to 6.50 ms**. This is eliminated
background work; cached publication was already about 6.5 ms and is measured with
5 ms polling. Foreground selection and normal LRU eviction remain available.

Both before/after benchmark runs passed. Six full-resolution revisits produced
six corrected-raster cache hits and no new full decodes or corrections; 1,000
viewport updates also left correction and publication counts unchanged. The
retained pair accounted for 1,455.43 MiB against a 3 GiB cache budget. Physical
footprint is recorded at settled and released states, but the variable samples
do not establish a memory reduction. Depths 2/8/32 observed initial populations
2/4/4, not fully populated retained caches.

The standalone CPU/Metal comparator also completed **2,725 comparisons, zero
render failures, maximum channel error 2/255** with Metal available. Its grid
retains the recipe/photographic coverage limits described above. Both C/C++ RAW
compatibility checks passed. No processing math, quality tiers, color defaults,
or RAW reference fixtures changed in this performance follow-up.

The final complete release suite, including the opt-in representative RAW roll,
passed in **289.942 seconds: 667 tests reported, 654 passing records, 13 opt-in
skips, zero issues**. An earlier full run had two failing tests: a retained-preview
timeout and a roll fixture still using the default Original base. RAW tests now
cancel work and verify model release between cases; the roll explicitly seeds
C-41 and keeps its preview/export pixel-change assertions. The focused rerun
passed 98 tests before the final full run. See the dated report for the initial
failure counts and scope. Strict formatting of the six touched Swift files,
`git diff --check`, and the strict MkDocs build passed. Packaging, hands-on
interaction, other opt-in performance/export studies, and full color studies
were not rerun.

### September 19 documentation audit verification

Rechecked the working tree based on `c4ad5ba`, including the existing uncommitted
Film Base/LookRecipe, preset migration, clipboard, preview-retention, scheduler,
and paired-reference changes. This audit changed documentation and site navigation;
it did not modify production code, test code, fixtures, or preference checkpoints.
Environment: arm64 macOS 15.7.9 (24G830), Swift 6.1.2, LibRaw 0.22.2, and the
local private RAW corpus.

| Check | Fresh result |
|---|---|
| Native release regression | 663 tests reported: **649 passing records, 14 opt-in skips, zero issues**, 460.713 s. Includes available RAW references and current recipe, migration, clipboard, retention, scheduler, viewport, and export regressions. |
| `bash native/test-raw-compatibility.sh` | Both C/C++ compatibility checks passed. |
| Color runner Python tests | All four passed; native processes are mocked, so this checks orchestration/input contracts only. |
| Color-study preflight | 40 complete triplets, two incomplete Lucky pairs. Does not resolve the study migration gaps below. |
| Documentation | Strict MkDocs build passed with MkDocs 1.6.1 / Material 9.7.7; local file links and `git diff --check` passed. |

The release suite was built with temporary module caches, `--jobs 2`, and
`--no-parallel`. An initial graphics-restricted run produced unavailable-render
failures and was interrupted; it is not a completed verification result. The
same compiled binaries passed the complete `--skip-build -c release --no-parallel`
rerun with normal macOS graphics access. See [Building](building.md) for commands
and the distinction between SwiftPM's sandbox and external graphics restrictions.

The 14 skips are the opt-in benchmarks and representative roll workflow. This
audit did not rerun the standalone CPU/Metal comparator, performance measurements,
full color studies/parser/export cohorts, legacy Python suite, packaging,
formatting, or hands-on photographic checks. The suite duration is not an
app-performance benchmark. Prior results below remain dated records.

### September 19 preset-flow record

The Develop inspector uses a grouped preset
menu so Tone & Light remains close to the film-base choice. Saving focuses the
name field, identifies case/diacritic-insensitive replacements, and keeps the
field open on failure. Develop's Reset Adjustments preserves film base,
calibration, and geometry and participates in undo/redo.

Factory and saved preset clicks now submit a single immediate edit, without
entering the continuous-drag preview path. Unchanged parameter values skip
persistence and rendering, while still revealing corrections during Original
comparison. The app-path regression with a viewport demand verifies one
submission per changed preset and none for repeated identical values; this is
work-count evidence, not a measured frame-rate improvement.

Version-one preset/clipboard documents migrate the public Develop adjustments
into version-two recipes. Legacy inversion choices and frame-specific settings
are intentionally not transferred. Reading does not rewrite the file. Unknown
document versions throw instead of appearing empty, preventing save/delete from
overwriting an unsupported library. Fifteen focused recipe/workflow tests passed,
and an AppKit-hosted inspector capture was visually checked at 1280 points wide.
This does not constitute hands-on testing of menu and keyboard interactions.
Changed Swift files passed strict formatting in that follow-up; the package-wide
lint reported warnings in other working-tree files.

The secondary preset pass caches decoded clipboard settings, empty contents, and
decoding failures by the pasteboard change count. One hundred unchanged inspector
availability checks perform one payload read; replacing clipboard contents
invalidates the result. A clipboard change during a read is not cached, and
providers without a revision counter continue reading each time. Copy reports
failure when neither the native nor text representation was stored. Upgrading a
v1 preset library now saves a byte-for-byte recovery copy before the first save
or deletion; v2 edits do not create extra migration backups. Library mutations
also sort once instead of repeatedly sorting the same snapshot.

The initial release run completed 655 tests in 358.064 seconds: 639 passing records,
14 opt-in skips, and two issues. The cropped-preview test still expected the old
color-negative GPU path; it now explicitly covers GPU slide corrections and
the required cropped C-41 CPU path. The separate calibrated-color reference test
initially threw `NSCocoaErrorDomain` code 4866 from reference alignment. Three
Lucky C200 JPEGs were rotated independently of their XMP; reviewed, hash-bound
orientation records now align these references without changing inputs,
calibration, or error thresholds. See the [reference-input contract](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md).
Preflight found 40 complete triplets and the same two incomplete Lucky C200 pairs
(DSCF5671 and DSCF5676), which remain excluded by corpus discovery.
The focused release rerun of recipes, preset workflows, and preview publication
completed successfully: 19 passing test records and one opt-in benchmark skip,
including both corrected cropped-renderer cases.

After the secondary fixes, the recorded complete release suite passed: 663 tests reported,
649 passing records, 14 opt-in skips, and no issues in 333.054 seconds. This
includes the previously failing calibrated-color reference test. Thirteen focused
clipboard, migration, workflow, and reference-input regressions also passed in debug.

| Evidence | Latest recorded result | Scope |
|---|---|---|
| Full native release suite, September 20 | 673 tests reported: 659 passing records, 14 opt-in skips; 277.426 s, zero issues | Current film-base/recipe parity, explicit flat-density CPU routing and exact app publication, plus default native/available RAW regressions. Performance and representative-roll opt-ins were not enabled. |
| CPU/Metal comparator, September 20 | 3,901/3,901 cases: 3,613 GPU comparisons within 2/255, 288 CPU-route checks, zero failures | Historical grid plus current bases, factory looks, public controls and combined grading. CPU routes are explicit exclusions from GPU parity. |
| Full native release suite with real roll, September 19 | 667 tests reported: 654 passing records, 13 opt-in skips; 289.942 s, zero issues | Fresh final run after speculative admission, RAW test lifecycle isolation, scheduler coverage, and the C-41 roll-fixture correction. Includes preview/export pixel changes, independent TIFF readers, and retained-decode re-export. |
| Retained-preview app-path benchmark, September 19 | Saturated-cache drain median 1,062.01 → 6.50 ms; unused requests 1/1/1 → 0/0/0 | Same harness and ten-file corpus; six retained revisits and 1,000 viewport updates add no full decode/correction work. [Raw samples and limits](../performance/retained-preview-2026-09-19.md). |
| CPU/Metal comparator, September 19 | 2,725 comparisons, zero render failures; maximum 2/255 | Fresh existing parameter-grid gate; not complete current factory-recipe or photographic coverage. |
| Full native release suite, September 19 | 663 tests reported: 649 passing records, 14 opt-in skips; 333.054 s | Preset workflow, clipboard revision caching and failures, lossless legacy backup, reviewed reference orientation, and the existing RAW, rendering, persistence, geometry, stacking, and export regressions. Run with macOS graphics access. |
| Work-reuse release checks, September 16 | Recorded complete suite: 639 tests passed, 14 optional skips; 318.915 s. Final follow-up: 25 focused passes, one opt-in skip; 12.039 s | Banded processing, CPU preparation reuse, cancellation/priority scheduling, viewport-region pixels, and revision-bound statistics. The [dated report](../performance/viewport-and-work-reuse-2026-09-16.md) predates retained full-sensor/corrected previews and two-worker scheduling. |
| Full native release suite, September 14 | 628 tests reported: 616 passing records, 12 opt-in skips; 232.231 s | The September 14 working-tree source, including local RAW references, repeated half-size determinism, one-worker Fuji unpacking, the bounded full-RAW edit proxy, persistence, geometry, stacks, contact sheets, output readers, and the three-frame roll. |
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
| Formatting, September 14 | Strict recursive Swift lint and diff whitespace check passed | Historical manifest, native sources, and tests; later working-tree lint results are recorded separately. |

### Earlier regression and package records

The following records retain their original dates, source revisions, and scope.

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
Builds used at most two jobs. That follow-up did not run a new full suite or RAW
benchmark or claim packaged-app performance. The [research note](../performance/research-directions-2026-09-12.md)
records the findings and next experiments.

The [September 13 implementation](../performance/implementation-2026-09-13.md)
moves settings encoding/writes off the main actor, adds exact large-image
Natural B&W lookup processing, reuses Darkroom analysis, supports GPU manual
crops, and publishes completed edits during sustained input. Its focused tests
and bounded measurements are recorded separately from the earlier full suite.

The [September 14 RAW compatibility repair](raw-decode-compatibility.md) restores
the established X-T5 source geometry and camera-WB conversion with LibRaw
0.22.2. The camera-scan stage/pixel references and all five correction scenarios
passed without changing their fixtures. C/C++ boundary checks also passed against
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
syntax, and diff whitespace checks passed. Local documentation links resolved;
MkDocs was unavailable in that local Python environment, so a complete
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

- The current public-recipe color workflow now completes. Further stock/default
  changes still need independent whole-profile evidence and user preference
  review; the [fresh report](roadmap-follow-through-2026-09-25.md) preserves
  individual-region regressions, collateral changes and failed transfer trials.
- The September 19 retained-preview report now measures app-model navigation,
  saturated-cache speculation, and physical footprint on a bounded local cohort.
  Fully populated larger rolls, sustained memory pressure, native input-to-screen
  latency, and current export performance remain outside that measurement.
  Initial lookahead populations at configured depths 8/32 are not full-capacity
  evidence. These checks do not establish photographic quality.
- Photographic CPU/Metal and version-4 TIFF checks now pass on the six-photo
  cohort above. This is bounded X-T5 evidence, not all cameras, all recipes or
  equivalence between one-pass preview and three-pass export decoding.
- Hands-on focus, grain, dust, tone, and color judgment across representative
  scans, including a realistic roll and real repeated captures.
- Preview/Photos judgment and install/launch proof on an independent Mac.
- Developer ID notarization and final distributed-artifact checks are last priority.
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
- The broader stock/capture calibration project, additional named-stock fitting,
  residual LUTs, halation work, and ML remain parked pending explicit owner
  direction. This does not suspend the active paired color/control study above.

## Build And Test

Use [Building](building.md) for commands, the [test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md)
for opt-in coverage, [Contributing](../contributing.md) for invariants, and
[native package documentation](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/README.md) for tool details.
