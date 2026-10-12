# Native macOS Development Status

This page owns current implementation status, verification, and limitations.
[Features](../features.md) describes the user tools; the
[roadmap](../improvements/MacOS-Native-Roadmap.md) owns priority.

**Source status reviewed October 12, 2026 (PDT). The current checkout adds
selective adjustment transfer, source-folder export defaults, editable dust
masks, optional saved healing strokes, the October 2 performance changes, and
open-roll restoration with Close All Scans for the 0.3 workflow, and the
October 10–11 settings/export/repair guards and cached CPU preparation, plus
the October 12 lossless PNG writer improvement.**
The implementation descriptions correspond to the 0.3.0 Beta 1 release source. Verification below is dated evidence, not an
automatic claim about every later edit. Local RAW tests depend on the untracked
`sample-raw/` corpus; CI cannot reproduce those cases without it.
The source-review date identifies documentation inspection; the execution dates
below identify actual tests and measurements.

## Release Position

The native Swift/SwiftUI app is the primary product. The latest release recorded
in this repository is [0.3.0 Beta 1](https://github.com/athoma28/Film-Scan-Converter/releases/tag/v0.3.0-beta.1),
version 0.3.0/build 4, an ad-hoc-signed Apple Silicon build for macOS 14 or later.
Later checkout changes and local packages do not establish a newer public release.

The packager assembles and validates self-contained app/ZIP artifacts and
supports Developer ID signing and notarization. A notarized distribution,
no-bypass Gatekeeper check, and installation on an independent supported Mac
have not been demonstrated. See the [release runbook](native-release.md).

## Current Application

| Area | Implemented behavior |
|---|---|
| Import and browsing | Standard images use a 1000px ImageIO preview. Camera RAW uses a colour-accurate draft, selected-file inspect and full-sensor 1-pass previews, and memory-bounded full-sensor neighbour lookahead. Completed decoded/corrected previews survive navigation; half-size corrected canvases can survive RAW-session eviction and bridge the next full decode. Settled panning submits no corrections. Supported whole-image point gestures on a selected full RAW can use a 2048px interaction source followed by exact full-source refinement; detailed viewport requests use the full source. Sidebar thumbnails are separate. |
| Inspector | Develop, Geometry, Calibrate, and Export pages; full-output dimensions in the header. Develop contains Film Base, Presets, Tone & Light, and Color & Balance. |
| Processing | Film bases Color C-41, cyan-mask, B&W, Slide, and Original; factory and user looks as public slider snapshots; tone, color, curves, wheels, dye crossover, and optional measured-density processing. B&W overall tone curves work on CPU and GPU. |
| Geometry | Auto Frame, freeform/fixed-ratio manual crop, two-point straighten, four-corner perspective with known frame ratios, projective grid and pixel nudges, rotation/flip, frame and aspect padding. Shared dimension prediction and preview/export geometry. Changing upstream geometry invalidates the dependent manual canvas crop; clearing that manual crop retains upstream geometry. |
| Viewport | Fit, pan, pinch, zoom steps, and 100% current-preview pixels. Original comparison and source-resolution upgrades preserve the viewed region. Overlays convert gesture coordinates using native magnification. Selection changes fit the new image. |
| Edits and rolls | Per-file persisted settings; session-local undo/redo with gesture coalescing; presets, clipboard transfer, selected/all look application, navigation in sidebar order, and export-state sidebar markers. Selective sync/paste transfers chosen Exposure, Tone, Color & Balance, Curves, and Grading groups while preserving each destination's local geometry, calibration, and repairs. Exposure is excluded from the initial group selection. Up/down reordering changes navigation and newly queued output order. Open scans, their order, and primary/multiple selection restore on launch. Close All Scans preserves saved corrections. |
| Dust and repair | Automatic candidate detection, editable Mark/Erase masks, optional Auto Repair Mask, and a healing brush with nearby automatic texture or an Option-click donor. Detection and masking alone leave pixels unchanged. Completed source-space strokes persist, undo/redo, and apply before geometry/inversion; repair editing temporarily shows the unframed source canvas. |
| Stacks | Opt-in adjacent repeated captures, translation alignment, Auto/Noise/HDR modes, bounded-to-full-resolution preview, and one export under the first capture's name/settings. Original captures merge in row bands through temporary disk storage; failures retain a usable preview and report status. |
| Export | Sequential full-resolution TIFF/JPEG/PNG/processed-RGB DNG, collision-safe naming, stage-boundary cancellation, and cleanup. Exports default beside each source; an optional common folder can be chosen or cleared. Queue jobs freeze their destinations and options. The selected RAW may retain its last three-pass decode for settings-only re-export. |
| Contact sheets | Selected/all PDF export with 12 corrected previews per Letter-size page, filenames, sidebar order, and one merged tile per enabled stack. Edits are captured at start; Original comparison and open editors do not alter the output. One sheet defaults beside the active image or stack anchor unless a common export folder is chosen. Progress, cancellation, staged commit, and collision-safe names share the app export workflow. |
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
  The [40 MP export benchmark](../performance/40mp-export.md) retains the dated
  stage hashes and oracle evidence.
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
  backing, retained CPU geometry, and completed display rasters count toward the budget. Display space
  is reserved before speculation. Only a selected image that exceeds the budget
  by itself is exempt. System memory pressure releases unselected entries and
  suspends background work. The current inspector has no cache-size control.
- RAW work uses at most two concurrent decodes on machines with at least 16 GiB
  RAM, and one on smaller machines. At most one worker is speculative; export
  preempts it. Editing gestures keep useful prefetch progress. Render scheduling
  still retains only one active and one latest pending request.
- Stacks decode originals sequentially and use temporary disk space of roughly
  two bytes per channel per pixel per non-anchor capture. The decoded anchor
  stays resident for registration and merging. Temporary files are removed on
  success, failure, and cancellation. A loaded flat field prevents stacking.
- CPU clipping diagnostics sample at most 65,536 pixels without full-frame
  Double expansion. Darkroom analysis shares sorted channel percentiles and
  retains pixel/chroma pairs during neutral-axis selection. See the
  [preview-analysis measurements](../performance/preview-analysis.md) for the
  bounded CPU workload.
- Settled previews retain a complete corrected raster; pan/zoom changes the
  viewport without new correction or statistics work. Active edits can use a
  viewport region plus overview before exact full-source refinement. CPU
  preparation belongs to cached full/proxy sources and reuses geometry and analysis
  after navigation; asynchronous statistics are bound
  to the published revision.
- Metal handles supported still corrections, including warm-hue recovery and
  manual crops with photographic tone versions 2–4. Saved dust repairs,
  measured-density processing, automatic frame geometry, perspective/straighten,
  legacy cropped density-print edits, near-flat density-print inputs (any channel
  log span below 0.001), and unresolved crop-dependent power-law analysis retain
  CPU fallbacks. Cropped Original/crop-only views also use CPU packing for exact
  pixels. Eligible photographic CPU fallbacks use a bounded overview and exact
  visible region during editing, then publish the complete image on release.
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
- Repair-bearing per-file settings use schema 3 so older builds reject the store
  and preserve its bytes rather than silently dropping strokes. Unrepaired stores
  retain schema 2. Candidate masks are temporary; strokes are source-local,
  bounded, non-destructive texture transfers. Original comparison omits repairs,
  and flat-field correction never heals the calibration image.

## Verification Summary

The entries record the source state and workload checked on each date. Full-suite
passes do not rerun skipped performance studies or prove photographic acceptance.
The standalone comparator now includes current Film Bases, all factory recipes
across editable bases, public control endpoints, and combined grading. Explicit
flat-density CPU routes are counted separately from GPU comparisons. This is
synthetic coverage, not complete photographic or export acceptance.
CI builds and tests the app on macOS 14 and 15. The macOS 15 lane also checks
formatting and an unsigned beta archive. The comparator, opt-in roll and
performance tests, and local RAW corpus are outside default CI.

Read the most recent relevant entry first. Earlier entries preserve the evidence
and failures that led to a decision; their source state, test counts, and open
checks remain historical. For example, the initial September 24 standalone
version-4 photographic Metal failure does not negate the later September 25 and
October 2 six-photo passes. Those later passes still do not cover repaired RAW
exports or independent repeated captures. Use the [performance index](../performance/index.md)
and [research index](../research/index.md) to find reports by question.

### October 12: 0.3.0 Beta 1 release-source verification

The release source is identified by tag `v0.3.0-beta.1`, version 0.3.0/build 4.
Local gates ran against the final native implementation and tests before the
release commit; the 412 recorded package/source/test/fixture/diagnostic hashes
remained unchanged across the final gates. Release metadata and documentation
were updated for publication. Untracked inspiration originals remain outside
the release source; private scans and generated outputs remain ignored.

On arm64 macOS 15.7.9 (24G830), Swift 6.1.2 and LibRaw 0.22.2, with normal macOS
graphics access:

- The complete release suite passed **924 tests: 902 passed, 22 intentional
  skips, zero failures, 241.592 s** after compilation.
- The full CPU/Metal comparator passed **4,608/4,608 cases**: 4,164 GPU
  comparisons, 444 verified CPU routes, no render failures, maximum RGB error
  2/255. This is synthetic coverage.
- The enabled photographic/output/roll gate passed **four test functions,
  no skips or failures, 162.525 s**. Six version-4 photographs (Fuji DSCF2833/2892,
  Pro Image DSCF5800/5809, Phoenix DSCF3079/3091) passed same-source CPU/Metal
  checks and exact reopened 16-bit sRGB TIFF comparisons. One repaired RAW
  restored two strokes and reopened an exact 3760 × 5264 TIFF. Three Fuji RAWs
  (DSCF2833/2851/2856) passed selected-look transfer, per-frame exception,
  sequential export, retained-decode re-export, and settings relaunch. The
  app-path TIFF/JPEG/PNG named-sRGB and processed-DNG metadata contract passed.
- Three freshly decoded preference frames (Fuji DSCF3115, Phoenix DSCF3079/3086)
  reproduced all **five frozen PNG/settings checkpoints exactly**, with historical
  medians and no ledger change. No checkpoint was excluded. Preflight found
  40 complete triplets and excluded incomplete Lucky DSCF5671/5676 from the wider
  inventory; no fitting or full-gallery comparison was rerun.
- C/C++ RAW compatibility, strict Swift formatting, legacy Python (24 tests,
  one opt-in skip), diagnostic runner/recipe contracts, 73 storage-tool tests,
  documentation links and strict MkDocs build passed.

Commands and switches remain in the [test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md)
and [Building](building.md). Ignored `dist/release-0.3.0-beta.1/` retains source
hashes, logs, binary fingerprints, photographic reports and preference replay
provenance. The release page records final source/artifact hashes, CI acceptance,
and clean-checkout package validation. A restricted initial native attempt could
not access window services and was cancelled; only the completed run with graphics
access is counted above.

Opt-in performance and native input/screen measurements were not rerun. Real
independent repeated-capture quality, photographic dust judgments, broader camera
coverage, notarization and independent-Mac installation remain incomplete.

### October 12: test coverage cleanup and stronger assertions

The follow-up review changed 19 test/helper files at revision
`2b4da0930df3ccebc08c1e3197a8ec242df448ac` plus the existing dirty tree and
preceding cleanup. Production code and committed fixtures stayed byte-for-byte
unchanged. The suite moved from 938 to 924 test declarations, with 236 fewer
lines net. This is consolidation of overlapping coverage, not a claim that every
remaining test has been individually justified.

Three AppModel smoke tests moved their unique assertions into deterministic
preview publication, unreadable-settings recovery, and preset replacement/reload
workflows. Batch-export and repeated-bitmap-lookup smoke tests were superseded by
stronger existing behavior checks. Duplicate neutral, profile round-trip, and
saved-adjustment decoding assertions were consolidated. All four white-balance
and five saturation fixtures remain, with their original exact/0.5 tolerances;
parameterized tests reduce boilerplate without deleting those inputs. Schema
validation now has one owner covering saved versions 1–4, every control, omitted
neutral defaults, unknown versions, and all 45 nonfinite field/value cases.

Weak unsigned-range and channel-count assertions now check actual LUT endpoints,
monochrome curve pixels, and exact color-only no-ops. Orientation uses eight
distinct colors and independent expected pixel order; resize checks sample mapping
for grayscale/RGB; straighten exercises a real guide through production correction.
Density analysis checks border exclusion with a negative control, and profile
loading checks the complete saved profile. Relaunch tests wait for completed
publication. Established instrumentation labels remain protected while additions,
ordering, and UI wording can evolve. RGB comparisons respect row strides and ignore
skipped storage bytes; dye/density tests separately preserve meaningful GPU opacity.
Final wheel cases use fixed samples with color/luminance expectations, and basic
inversion has an independently calculated working-space dye response. Historical
RAW bytes, saved versions, cache ownership/admission, cancellation, Undo/Redo,
export tags, failure cleanup, and opt-in measurement contracts were retained.

On arm64 macOS 15.7.9, Swift 6.1.2, with normal graphics access, the complete release
suite reported **924 tests: 902 passed, 22 intentional skips, zero failures,
228.911 s** after compilation. The per-gate 377 source/test/fixture hashes stayed
unchanged during verification. Subsequent test-only refinements—explicit historical
neutral values, nonempty factory catalog, meaningful GPU alpha, and deterministic
numerical oracles—passed the focused release gates: **43/43 tests in 10.205 s** and
**71/71 in 0.114 s**, both without skips or failures. These final refinements were
not followed by another complete-suite run. Strict formatting of all touched Swift
files, whitespace and documentation checks passed.

The [test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md)
records the focused commands and ownership. Ignored
`dist/test-quality-cleanup-2026-10-12/` retains the isolated `test-only.patch`,
starting test snapshots, final checked source, per-gate fingerprints, logs and
`verification.json`. The separate comparator, C/C++ compatibility gate, opt-in
performance/roll/photographic export cohorts, and packaged release were not rerun
for this test-only change. The earlier clean-code entry records their prior checks.

### October 12: clean-code and regression review

The 30-minute cleanup pass used revision
`2b4da0930df3ccebc08c1e3197a8ec242df448ac` plus the existing dirty tree,
preserving unrelated work. It changed 16 source/test files with 225 fewer lines
net: selection preparation, preview workers, export queue execution, RAW shim
calling/copying/diagnostics, and renderer input preparation now have named
responsibilities. ImageIO exports share staging/finalization/commit, while
format-specific pixels/options and the custom DNG path remain explicit. Unused
private/internal helpers, a log, a label, and a TIFF type case were removed.

Preview assertions now read complete visible RGB rows with fail-fast layout,
dimension, provider, and buffer checks, excluding row padding and skipped alpha.
Six identical tone-grid inputs remain covered in their dedicated test; the
identical TIFF/PNG bitmap layout test is consolidated. The all-film smoke fixture
is deterministic and odd-sized. Historical pixel, saved-version, cancellation,
persistence/recovery, and opt-in performance contracts were retained.

On arm64 macOS 15.7.9 with Swift 6.1.2 and normal graphics access, the complete
release suite on the final production code reported **938 tests: 916 passed,
22 intentional opt-in skips, zero failures, 233.769 s** after compilation. All 377 source/test/
fixture hashes remained unchanged around that run. Three subsequent test-only
assertion replacements in perspective, crop-ratio, and RAW-dust suites passed a
fresh focused release gate: **3 test functions, no skips, zero failures, 26.895 s**,
including two perspective rotations and four crop geometries. The enabled RAW
case saved/restored two repairs and reopened a 3760 × 5264, 16-bit sRGB TIFF whose
pixels exactly matched the production CPU output; the source RAW hash stayed
unchanged. This does not assess photographic restoration quality.

The full CPU/Metal comparator passed **4,608/4,608 cases**: 4,164 GPU comparisons,
444 expected CPU routes, no failures, maximum RGB channel difference 2/255.
C/C++ RAW compatibility, strict formatting of all touched Swift files, whitespace,
and documentation-link checks passed. The release build linked the native app and
diagnostic products as part of the suite. An earlier complete pass reported
939 tests before removal of the identical layout test; an initial compile rejected
inputs changed during editing and provides no verification claim.

Commands remain in the [test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md).
Ignored `dist/clean-code-pass-2026-10-12/` retains `verification.json`, logs,
source/hash snapshots for the complete and final focused gates, binary fingerprints,
and `cleanup-only.patch`, isolated from the pre-existing dirty changes.
The separate color-preference workflow, broader photographic cohorts, opt-in
performance/roll/interaction measurements, and packaged release were not rerun.
No performance improvement, changed color default, or release validation is claimed.

### October 12: non-JPEG export writers

The [non-JPEG export report](../performance/non-jpeg-export-2026-10-12.md)
records the final PNG-only source at revision
`2b4da0930df3ccebc08c1e3197a8ec242df448ac` plus its recorded dirty tree.
ImageIO's fixed Average PNG filter reduced writer medians by **20.9–27.1%**
and complete engine export medians by **6.2–11.8%** on three 7752 × 5184 RAWs,
using the same neutral C-41 tone-version-4 profile and three-pass decode.
All 27 final PNGs matched the corresponding complete-pixel-verified filter
probe hashes and were removed. PNG compression bytes change; file sizes ranged
from 0.061% smaller to 0.496% larger. The unchanged TIFF None/LZW and DNG
writers also reproduced their complete baseline file hashes in fresh final
exports. A DNG pointer trial saved only 2–5 ms in packing with inconsistent
total times and was restored exactly to the initial dirty source.

The focused release command in the [test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md)
reported **53 test functions, two opt-in skips, zero failures**, in 3.752 s
after compilation. It includes exhaustive 16-bit PNG boundary cases, an
independent DNG parallel-band/scalar-tail oracle, staged cleanup, cancellation,
late collisions and ImageIO/sips inspection of actual app exports. The skipped
checks were the six-frame photographic suite and real-RAW dust exports.
The production app and diagnostic builds passed. Both frozen renderer arms
freshly decoded the three preference RAWs and matched all five historical PNG
hashes, exact BGR16/decoded pixels and normalized settings without changing the
checkpoint ledger. Paired-study diagnostics retain adaptive PNG encoding for
that byte compatibility.

Source, input, object/executable fingerprints, commands, raw observations,
memory/drift/cleanup records and source snapshots are retained in ignored
`dist/non-jpeg-export-2026-10-12/`, including `final-manifest.json` and
`final-comparison.json`. Strict formatting passed for changed Swift files.
The complete native suite, separate Metal comparator, installed-app/package,
native interaction, larger RAW/photographic cohorts and energy were not rerun.
These engine measurements exclude app queue/UI time and do not establish a
general export multiplier or population tail latency.

### October 11: roadmap workflow and retained CPU preparation

The [roadmap loop report](roadmap-loop-2026-10-10.md) records settings recovery,
late export collisions, donor-safe dust-mask planning, stale/cancelled Auto Frame,
async action/gesture history, export preparation cancellation and session-owned
CPU preparation, plus direct-Heal donor and strict mask-footprint checks. The
final frozen workflow cohort passed the complete release suite:
**937 tests reported, 22 intentional opt-in skips, zero failures, 165.268 s**;
376 source/test hashes and four compiled executable hashes were verified unchanged
around the run. Earlier failing fixture-history and native-field focus checks,
their corrections and scheduling exclusion remain in the loop report. The numeric
field fixture separates native events and verifies editor ownership without
changing production controls or its assertions/deadline. A fresh repaired
RAW contract passed in 18.082 s with an exact reopened 3760×5264, 16-bit sRGB TIFF.
The final engine also passed 4,608 comparator cases, a 288-case dust equivalence
oracle and all five freshly rendered preferred looks. Color defaults and the
preference ledger were unchanged. Strict formatting passed.

The [CPU cached-revisit report](../performance/cpu-revisit-preparation-2026-10-11.md)
measures 15.3–20.9% lower first committed-edit medians in two RAWs with CPU geometry,
with higher charged and sampled physical retention. The
[sustained report](../performance/sustained-preview-2026-10-11.md) records 24
count-limit switches, exact revisits, simulated pressure/recovery and model
release. These app-model and output checks do not establish native screen
latency, controlled OS pressure, photographic dust quality or a distributed
artifact. Distribution, Computer Use and independent repeated-capture quality
remain deferred.

The fresh [Detailed cached-revisit report](../performance/detailed-cached-revisit-2026-10-11.md)
measures a 90.6 ms first gesture publication median against bracketed baseline
medians of 308.3–311.8 ms, with all 18 exact CPU guards passing. Full refinement
remained about one second and sampled physical footprint was higher. The broader
dirty cohorts include several workflow changes, so this is a bounded workload
comparison. The [eight-RAW byte-capacity report](../performance/sustained-byte-capacity-2026-10-11.md)
records 32 switches under the normal 3 GiB budget: previously warmed full sessions
were evicted below the eight-session count limit while the pressure-drop handler
count remained zero.
It does not establish a fixed three-frame ceiling or controlled OS-pressure behavior.

### October 10: three-RAW JPEG export follow-up

The [three-export report](../performance/jpeg-three-export-2026-10-10.md) records
exact directional X-Trans homogeneity reordering in the production camera-scan
decoder. The final source retains the initial dirty Swift correction code after
prepared/fused CPU trials increased the measured profile-stage time. Existing
scratch storage holds thresholds; RAW quality settings and film/look defaults
remain unchanged. Five matched rounds on each of three 40 MP scans reduced
complete RAW → C-41 profile → JPEG engine medians by 32.4–34.3%, with all 45
JPEGs byte-identical. The final five RAW identity tests, 96 optimized C++ oracle
maps, 1,883 current CPU/Metal comparisons, and five fresh preferred-look checks
passed. Cleanup retired about 1.49 GiB of generated data/caches and retained
6.31 MiB of task evidence. Full-suite, native UI/input latency, broader camera
acceptance, and packaging were not rerun.

### October 10: JPEG export correction and retained revisit canvases

The working tree on `2b4da09` now runs initial photographic conversion through
bounded CPU workers and keeps independent half-size corrected RAW canvases on
departure. Matching canvases survive source-session eviction, retain full logical
zoom dimensions, and bridge directly to full RAW detail without a blocky draft
replacement or redundant inspect pass. Original, changed edits, temporary editor
canvases and enabled stacks cannot reuse mismatched pixels. Snapshot memory is
charged to the preview budget; pressure drops cached snapshots while preserving
the currently visible canvas, and Close All/flat-field changes invalidate pending
work. The change preserves unrelated pre-existing working-tree edits.

Fresh release validation on macOS 15.7.9 / Apple M4 Pro:

- Release app/test build passed. The [focused regression command](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md) completed with **97 test functions passed, two opt-in skips, zero failures** (Swift Testing summary: 99). Skips were the six-photo photographic export study and 640-entry persistence/preview replay. New cases cover half-size geometry/color, independent bitmap ownership, LRU accounting, edited RAW revisits, stale-edit rejection, Original, and pressure/Close All/flat-field invalidation. Existing export, publication, viewport, dust repair, open-roll and explicit RAW-detail checks also passed.

- The current CPU/Metal comparator completed **1,883/1,883 cases**: 1,439 GPU
  comparisons and 444 explicit CPU routes, zero failures, maximum error 1/255.
- Nine complete 7752 × 5184 C-41 JPEG exports were byte-identical across frozen
  baseline, candidate and baseline recheck. Correction medians were 8.330,
  3.474 and 18.741 seconds. Machine drift prevents a stable general end-to-end
  multiplier; see [the complete measurement](../performance/jpeg-export-2026-10-10.md).
- All five preferred-look PNG and settings checks passed after three fresh RAW
  decodes with the recorded historical medians. No presets or color defaults changed.

The navigation regression uses deterministic injected RAW tiers and model
publication, rather than a native-input/screen-latency measurement. Full default
regression, sustained navigation/pressure profiling, full reference galleries,
packaging and installed-app interaction were not rerun for this change. Final source hashes, focused logs and a source snapshot are retained in ignored `dist/jpeg-export-2026-10-10/preview-validation.json` and its sibling archives. Changed Swift files passed strict formatting; the documentation gate checked 64 pages and 586 links with zero errors.

### October 3: workspace controls and bounded factory previews

The working tree on `2b4da09` adds a native toolbar, resizable/collapsible inspector,
window-local hide/restore side panels, and exact numeric entry for adjustment and
grading sliders. Numeric drafts preserve hidden precision, validate locale-aware
finite values, constrain ranges/steps, commit once, and reject source/value changes.
The optional nine-look strip uses retained decoded sources, production CPU renders,
160px tiles and immutable 256px analysis, with a 500 ms all-or-nothing budget and
window-session fallback to the named menu. Processing defaults are unchanged.

The release benchmark in ignored `dist/preset-preview-full-2026-10-03/report.json`
records **45 complete-strip calculations at 28.11–60.43 ms** on macOS 15.7.9
(24G830), arm64, Swift 6.1.2. It includes five synthetic cohorts and four
7752×5184 camera-scan, one-pass full-sensor sources: Fuji 400 DSCF2833, Phoenix II
DSCF3086, Pro Image DSCF5800 and Shanghai GP3 DSCF3192. Each sample includes source,
analysis/flat-field preparation, all nine renders and bitmap packing; RAW decoding
occurs before timing. The first and four repeated calculations use fresh caches;
this is not process-cold startup or an end-to-end import latency measurement.
The earlier inspect-size report in `dist/preset-preview-strip-2026-10-03/` remains
separate evidence and is not a full-sensor measurement.

Debug and release app builds pass. The final focused debug run reports **39 tests,
zero failures, one intentional skip** (38 executed); the skipped timing benchmark
passed separately in release with all 45 samples above. Coverage includes native
numeric Return/Escape/focus-loss and source guards, look application/undo,
thumbnail pixels/analysis, stale-publication/budget fallback, viewport transforms,
and a 980×640 hosted window retaining its resized inspector, preview identity,
zoom and pan across collapse/restore. The hosted-view PNG was inspected. Formatting,
`git diff --check`, and the public documentation link check pass.

Earlier harness failures were resolved: the restricted runner lacked suitable
native-window access, the isolated numeric host did not expose process-local AX
children (the test now sends events only to its own control), and offscreen
AppKit animations prevented inspector sizing from settling (the hosted test now
disables animations). These were followed by the passing native-window run with
normal graphics access. Full-suite, packaged-app, full-resolution export, and
photographic color/parity checks were not rerun for these interface-only changes.

### October 3: full X-T5 upstream-color experiment

The [fixed-recipe decoder-policy study](../research/xt5-matrix-study-2026-10-03.md)
completed all 40 available pairs across both decode tiers and three recipes,
plus five frozen preferred looks: **500 corrected renders and 90 full-resolution
JPEGs**. The baseline/candidate use isolated snapshots of `2b4da09` plus the
existing working tree; only the candidate's color compatibility helper is
disabled, with geometry retained. No production decoder or color default changed.

Fresh checks pass **480 exact real-app parser/pixel comparisons**, **500 actual
900px GPU comparisons** (maximum error 1/255, zero fallbacks), independent full
decompression/hash/dimension validation for all 90 JPEGs, all 86 paired
source-geometry/unpacked-mosaic comparisons, and all five unchanged preference
PNG checkpoints in the baseline. The full Fuji DSCF2833 baseline also matches
all five existing RAW-stage fixture hashes. GPU checks use proxies from each
decode tier and do not establish full-resolution Metal equality.

The candidate is rejected: full Clean Invert color-reference RGB MAE increases
from 37.95 to 44.21 (+16.5%); 22/34 color photographs worsen and every saved
preferred look changes. All 40 frames remain scored. Four preview/seven full
candidate registrations fail; displacement review gates and photographic
failures remain in the reports. The scorer returns failure for those gates,
after complete rendering. Independent full-registration sensitivity leaves the
decision unchanged. Two incomplete Lucky pairs remain input exclusions.

Ignored `dist/xt5-matrix-study-2026-10-03/` holds pinned binaries, source/input
hashes, per-frame checks, galleries and the independent validation records.
This is a completed diagnostic experiment, not a new profile calibration,
unseen-roll validation, full-suite run, packaged-app or performance acceptance.

### October 3: open-roll restoration and Close All Scans

The app now restores ordered scan paths, the primary scan, and multiselection
from a separate versioned roll document, then loads the selected preview with
its saved corrections. Offline paths remain in the sidebar. Close All Scans
clears browsing work, previews, thumbnail caches, and transient history while
preserving source files and per-file corrections; active exports block closing.
Thumbnail generations prevent cancelled old-roll workers from clearing or
publishing over replacement requests. Coalesced background saves preserve
unreadable/unknown roll documents, report failures, and retry on flush. Orderly
quit drains both correction and roll writers, including edits arriving during
an in-flight write. Enabled stacks, export jobs, and flat fields do not restore.

Fresh checks on Swift 6.1.2/macOS 15.7.9 (24G830), from `2b4da09` plus the
pre-existing working tree and this additive workflow change:

- Focused native release regression: **121 tests passed, zero issues or skips**,
  23.064 seconds, with normal macOS graphics access. This includes 15 new
  storage/persistence/app tests plus existing app model, observation, per-file
  persistence, export-destination, preview-invalidation, and stack workflows.
  New restore tests use copied committed PNG fixtures; existing RAW-enabled
  cases use the local corpus.
- Standalone release app build and strict formatting of all seven changed/new
  Swift files passed. Documentation links/navigation: **60 pages, 523 links,
  zero errors**; whitespace checks passed.
- The first test build exposed missing inner `try` expressions in three test
  assertions; corrected before execution. The restricted run could not render
  AppKit thumbnails and was interrupted; the graphics-enabled run above passes.

Source/fixture hashes and build/test logs are in ignored
`dist/open-roll-2026-10-03/`. This is focused source verification; the full suite,
standalone comparator, photographic exports, performance studies, and packaged
UI/distribution acceptance were not rerun. Processing math and color defaults
were not changed by this feature.

### October 2: documentation and research organization

This pass reviewed current source contracts, diagnostic flags, dated reports,
and available local manifests. It added the research/performance indexes,
updated stale source/release and migration claims, separated completed
opportunities from open questions, and defined
[documentation ownership and checks](documentation-maintenance.md).
Historical results and failed experiments retain their original scope.

The dependency-free public Markdown checker passed across 60 pages and 523
links, including local/source targets, heading anchors and navigation
reachability. Temporary fixtures also verified rejection of missing
targets/anchors, private artifact hyperlinks, and missing/unreachable navigation
pages, while allowing fenced/inline examples
and valid same-repository source links. A strict MkDocs build with MkDocs 1.6.1
and Material 9.7.7 passed; generated-site HTML inspection found no missing local
pages, assets or anchors. The new documentation CI job is configured to run
the public-link check; no remote CI execution is claimed here.

Read-only color `doctor` and `plan` checks found 40 complete triplets and two
incomplete Lucky exclusions. These are setup checks. No native regressions,
benchmark measurements, parser probes, galleries, export checks or Metal
comparisons were rerun for this pass. File hashes confirm that existing app
source, tests and the preference ledger were preserved. No tools in this pass
wrote private inputs or study images.

### October 2: native performance implementation

The [implementation report](../performance/implementation-2026-10-02.md) records
the exact density-print input lookup, worker-prepared thumbnails and shared RAW
metadata, combined dust morphology, resident stack reference, bounded DNG
packing, and cancellation of remaining obsolete preview stages. It preserves
color defaults, preferred looks, output bytes, and ordinary point-edit progress.

Fresh verification on Apple M4 Pro/48 GiB, macOS 15.7.9, Swift 6.1.2, against
`2b4da0930df3ccebc08c1e3197a8ec242df448ac` plus the recorded working tree:

- Complete native release suite with photographic exports enabled: **828 tests,
  16 reported skips, zero issues**, in 473.691 s. Both DNG cleanup regressions
  pass after correcting filename comparisons in their assertions.
- Production comparator: **4,608/4,608 cases**, including 4,164 GPU comparisons
  within 2/255 and 444 verified CPU routes; zero render failures.
- Six 7752 × 5184 RAW app-path TIFF exports reopen with exact production CPU
  pixels and independently verified 16-bit named-sRGB metadata. Same-source
  app-preview and CPU/Metal comparisons differ by at most 1/255. Interactive
  one-pass versus export three-pass RAW differences are recorded separately;
  this is not a claim that the two source tiers are identical.
- Three fresh RAW decodes reproduce all five preferred-look PNG hashes and
  normalized settings exactly; the preference ledger remains unchanged.
- Production release build, C/C++ RAW compatibility checks, strict package-wide
  Swift formatting, and whitespace checks pass. Final source/test/fixture and
  production-binary hashes are recorded with verification.

Matched baseline/candidate/baseline-recheck probes show **7.69–10.00% lower CPU
correction time** on one 40 MP RAW and **65.51–67.08% lower dust-detection time**
on two synthetic masks, with exact outputs. RGB DNG first-write peak footprint
falls from about 463 to 249 MiB; its reusable packing buffer is at most 16 MiB.
Observed drift does not establish a general DNG, stack, or RAW-thumbnail latency
gain. These are bounded measurements, not end-to-end app-speed claims.

Ignored evidence is under `dist/performance-implementation-2026-10-02/`, including
frozen release objects, source/input hashes, matched measurements, full logs,
preference checks, and the six export reports. Native pointer replay, the other
opt-in performance/roll studies, energy and physical-disk counters, packaged
distribution, and independent-Mac acceptance were not run.

### September 30: code cleanup and regression review

The follow-up review fixes repeated stationary healing samples applying extra
feather blends, current flat-field cancellation retaining the export gate,
missing progress callbacks for sequential cancelled exports, and directory-symlink
export destinations failing Foundation's URL-based directory enumeration. Name
reservation now inspects the resolved physical folder while retaining the chosen
destination path. Prepared calibrated inversion uses optional binding in place
of force unwraps; its arithmetic and color defaults are unchanged.

Tests now await actual auxiliary-task completion before checking stale results,
verify progress callbacks and reopened output pixels/formats, exercise physical
folder aliases, and reject malformed dust inputs independently and atomically.
Additional coverage checks stationary brush samples, immutable donors, repair
visibility pixels, viewport bounds and analysis invalidation. Pixel comparisons
require matching dimensions, supported layouts, and complete buffers; the lazy
source lifetime test uses independent analysis storage.

Fresh verification on Apple M4 Pro/48 GiB, macOS 15.7.9 (24G830), Swift 6.1.2,
against `2b4da0930df3ccebc08c1e3197a8ec242df448ac` plus the current working tree:

- Complete native release suite: **810 tests, 17 reported skips, zero issues**
  in 383.364 s; final source and binary hashes remain unchanged.
- Focused regression suites: **115 tests, one reported skip, zero issues**.
- Production comparator: **4,608/4,608 cases**, including 4,164 GPU comparisons
  within 2/255 and 444 verified CPU routes; zero render failures.
- Three fresh RAW decodes reproduce all five preferred-look PNG hashes and
  normalized settings exactly; the preference ledger remains unchanged.
- All **24 Python diagnostic tests**, C/C++ RAW compatibility checks, strict
  Swift formatting, whitespace checks, and production app/test builds pass.

Evidence and source/binary hashes are in ignored `dist/clean-code-2026-09-30/`,
with the final manifest in `verification.json`. Earlier logs retain 14 rendering
failures under restricted graphics access and the failing symlink regression;
normal macOS graphics access and the directory-enumeration fix resolve them.
The opt-in performance, representative-roll, and photographic-export studies,
manual pointer replay, real-scan dust-restoration quality, independent-Mac
acceptance, and distribution checks were not run. These results establish the
recorded code and pixel contracts, not complete photographic acceptance.

### September 30: 0.3 workflow implementation

Selective sync and clipboard paste now transfer chosen groups to the current,
selected, or all open scans. Exposure starts unchecked. Partial transfers retain
the destination tone version, preflight incompatible legacy Tone/Grading as one
batch, and preserve calibration, geometry, and local repairs. Matching groups,
including All, retain exact legacy representations and create no edit/history.
First-load paste retains automatic film-base initialization through Undo/Redo.
The original full batch action keeps its existing edited-marker/history behavior.

Exports default beside each source, with an optional common folder override.
Queued jobs reserve names per physical folder and freeze destinations/options,
including appended jobs. Stacks use their anchor folder; one PDF uses the active
image/anchor folder. Mixed-folder, source-preservation, collision, queue, stack,
and contact-sheet regressions pass.

Dust detection creates temporary editable masks without changing pixels.
Explicit mask repair and completed healing strokes save source-space texture
transfers before geometry/inversion. Repair-bearing stores use schema 3, flat
fields remain untreated, and repaired previews use CPU fallback. Brush input
waits for the published source canvas; repair changes reject older completed
frames. App tests cover mask retention, donor rejection, undo/relaunch, unchanged
source bytes, and exact reopened synthetic full-size PNG pixels after framing.

Verification uses the Apple M4 Pro/48 GiB, macOS 15.7.9 (24G830), Swift 6.1.2,
and baseline `2b4da0930df3ccebc08c1e3197a8ec242df448ac` plus the current working
tree, including the pre-existing September 28 CPU work. Logs, source/input
provenance, and frozen renderer artifacts remain in ignored
`dist/0.3-workflow-2026-09-30/`.

- Complete final native release suite: **801 tests, 17 reported skips, zero issues**
  in 385.606 s; sources and release binaries remain unchanged through verification.
- Final focused workflow/compatibility checks: **42 tests, zero issues**.
- Production comparator: **4,608/4,608**, including 4,164 GPU comparisons within
  2/255 and 444 explicit CPU routes; zero failures. Dust repairs have separate
  CPU-routing coverage and are not a GPU repair claim.
- Three fresh RAW decodes and all five preferred-look renders match the unchanged
  ledger PNG hashes and normalized settings. Before/after source, input, and
  renderer integrity checks pass. The diagnostic comparison adds only the absent
  `dustRepairs: []` decode default; nonempty repairs remain significant.
- All **24 Python diagnostic tests**, C/C++ RAW compatibility checks, and strict
  Swift formatting pass; production app and test builds pass.

This is source implementation and bounded correctness evidence. Real-scan
restoration quality, detection accuracy, grain/edges, full-resolution RAW repair
export agreement/cost, native pointer replay, the opt-in roll/performance studies,
independent-Mac acceptance, and distribution checks were not run. No release was
published. The earlier 800-test run reported one full-batch marker issue; the
focused and complete final runs cover the corrected behavior. The compact
verification manifest is `verification/verification.json` within the ignored
evidence directory above.

### September 28 CPU point correction and viewport overviews

The [follow-up report](../performance/cpu-point-work-2026-09-28.md) records scalar
photographic channel work, prepared wheel activity and correction at the
requested CPU overview size with unchanged nearest-neighbor sampling. Geometry
and bound changes rebuild the single cached overview with current byte accounting.

On the tested 40 MP one-pass preview source, bracketed ordinary-release CPU
medians fell about 55–57% for geometry viewports, 30–31% for saved calibrated-color
rendering and 21–22% for slide. Monochrome measured 41–57% lower time, with a
variable baseline recheck. Current C-41/cyan-mask density-print timings do not
establish a speedup. Two additional 2048px photographs match exactly; their
contended timing samples are excluded from speed claims. All 45 complete/detail
outputs, 18 overviews and 72 unique branch oracles match baseline pixel hashes.
The tested overview caches retain about 12 MiB less raw storage; process footprint
was not measured. Timers exclude decode, first full warp, packing, export,
publication and screen presentation.

Fresh verification on M4 Pro/48 GiB, macOS 15.7.9 and Swift 6.1.2:

- Complete native release suite: **760 tests, 17 reported skipped checks, zero issues**.
- Ordinary production comparator: **4,608/4,608**, including 4,164 GPU comparisons
  within 2/255 and 444 explicit CPU routes; zero failures.
- Five preferred-look PNGs from fresh RAW decodes and preserved historical
  medians match the unchanged ledger hashes exactly.
- The reusable bounded CPU probe passes preflight, provenance/CLI checks and an
  end-to-end proxy run; production app/Lookbook builds, strict Swift formatting
  and whitespace checks pass.

Evidence remains in ignored `dist/performance-research-2026-09-28/`, its separate
preference directory and `dist/cpu-point-work-helper-smoke-2026-09-28/`.
Six-frame photographic TIFF validation, native pointer replay, export throughput,
energy/physical footprint, packaged release and MkDocs rendering were not rerun.
Background load and small sample counts limit general timing claims.

### September 27 native performance implementation

The [implementation report](../performance/implementation-2026-09-27.md) records
prepared CPU rendering state, exact CPU viewport detail with a bounded overview,
deferred RGBA16 backing, auxiliary image workers, and independent bounded export
writers. Generation and cancellation guards preserve current calibration and
overlay publication. Geometry/overview storage participates in cache admission.

On one 40 MP RAW, final production CPU correction measured 3.388 seconds for
monochrome versus baseline medians of 6.923–7.005 seconds. Warmed straighten and
perspective viewport work fell about 88–92%, with exact detail hashes. Color
timings fell within the two baseline runs' variation, so no color speedup is
established. These windows exclude decode, first geometry warp, bitmap packing,
writing, publication and screen presentation.

Fresh verification on M4 Pro/48 GiB, macOS 15.7.9 and Swift 6.1.2:

- Full native release suite: **759 tests, 17 reported skipped checks, zero issues**.
- Standalone comparator: **4,608/4,608**, with 4,164 GPU comparisons within 2/255
  and 444 explicit CPU routes.
- Five fresh preference PNGs match the unchanged ledger hashes exactly.
- Six 7,752×5,184, 16-bit named-sRGB app TIFFs reopened with exact production CPU
  pixels. Same-source app and Metal previews differ by at most 1/255; one-pass
  preview versus three-pass export differences remain separate.
- Standalone production app build, strict Swift formatting and whitespace checks pass.

Source/input hashes, logs and measurements remain in ignored
`dist/performance-implementation-2026-09-27/` and the fresh preference directory.
Export throughput, physical footprint, native pointer replay and packaged release
were not measured in this pass.

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
[test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md#current-default-coverage) lists focused commands.

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

### September 22 photographic tone fix

The [photographic tone implementation](photographic-tone-controls-2026-09-22.md)
replaces the audited operators for new edits, keeps float precision through
curves, and enables cropped density-print GPU previews. Legacy edits retain their
version until explicitly upgraded. All five preferred-look hashes match fresh
renders. The expanded 4,132-case CPU/Metal comparator and final full native release suite
(687 tests, zero issues, 396.198 s) pass; the implementation report records
photograph, full-resolution and native app checks.

### Edit preservation and settings recovery

Batch look application preserves the destination's transferred controls and
film base instead of reclassifying an already edited frame. If the per-file
settings document cannot be read, the app does not overwrite it with an empty
session. Saving resumes after repair or removal; recovered unrelated entries
survive, while current-session values win for matching files. The September 20
repair passed 23 focused tests and a complete 677-test release run with the
representative RAW roll. Later complete-suite results above cover the current
source.

### Retained-preview performance

The [September 19 app-path report](../performance/retained-preview-2026-09-19.md)
measured the cache-admission policy on a ten-file local RAW cohort. Avoiding
speculative decodes that cannot fit changed three saturated-cache background
drains from a 1,062.01 ms median to 6.50 ms and removed one unused decode per
revisit. Six retained full-resolution revisits and 1,000 viewport updates added
no decode or correction work. The paired cache held 1,455.43 MiB against a
3 GiB budget. Variable physical-footprint samples do not establish a memory
reduction, and the configured 8/32-depth cohorts were not fully populated.

## Remaining Verification And Limitations

- The current public-recipe color workflow now completes. Further stock/default
  changes still need independent whole-profile evidence and user preference
  review; the [fresh report](roadmap-follow-through-2026-09-25.md) preserves
  individual-region regressions, collateral changes and failed transfer trials.
- The [October 11 sustained navigation](../performance/sustained-preview-2026-10-11.md)
  checks 24 three-RAW switches under a two-session count limit, simulated app
  pressure/recovery and physical footprint. The
  [cached CPU edit study](../performance/cpu-revisit-preparation-2026-10-11.md)
  establishes a bounded latency benefit with higher settled physical memory.
  Fully populated larger rolls, controlled OS memory pressure, native input-to-screen
  latency, and general export performance remain outside those measurements.
  Initial lookahead populations at configured depths 8/32 are not full-capacity
  evidence. These checks do not establish photographic quality.
- Photographic CPU/Metal and version-4 TIFF checks now pass on the six-photo
  cohort above. This is bounded X-T5 evidence, not all cameras, all recipes or
  equivalence between one-pass preview and three-pass export decoding.
- Hands-on focus, grain, dust, tone, and color judgment across representative
  scans, including a realistic roll and real repeated captures.
- Preview/Photos judgment and install/launch proof on an independent Mac.
- Developer ID notarization and independent-Mac distribution review remain open.
- Native dust tools now have deterministic and app-workflow coverage; realistic
  grain, scene edges, donor selection, and detection accuracy still need hands-on
  photographic review. Lens-distortion correction and vendor-specific tethering
  are absent. Sidebar reordering persists across launches and uses up/down buttons; drag
  reordering is not implemented. Roll restoration retains offline paths; it does
  not restore enabled stacks, export queues, flat fields, or transient history.
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
