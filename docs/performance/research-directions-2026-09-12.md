# RAW decode, editing, and export research directions

September 12, 2026. Source inspection of `4e962c1` plus the working-tree repairs
described below. This is a research plan, not a new performance benchmark.
The owner's estimate that decode is within roughly 20–30% of Camera Raw is a
useful priority signal; it is not a measured comparison of equivalent stages.

The strongest next investment is interactive editing. The current app already
uses GPU correction and a heavily optimized X-Trans decoder, but requests still
do avoidable work before rendering, render more pixels than the viewport needs,
and switch to CPU processing after ordinary geometry edits. A faster demosaic
alone will not fix those problems once a RAW has loaded.

Follow-up: the [B&W tonality investigation](bw-tonality-2026-09-13.md) identifies
a flat interval in the default monochrome curve and independently reproduces
HDR merge clipping. Those quality losses should be addressed before attributing
the reported painted-on fine detail entirely to demosaicing.

The [second research pass](research-pass-two-2026-09-13.md) adds bounded
measurements of persistence and an exact Natural B&W lookup prototype, plus
HDR precision/weighting counterexamples. It narrows the implementation order
without running a RAW benchmark sweep.

## Repairs made during this investigation

The only initial tracked modifications were additions to `AppModel.swift`,
`ContentView.swift`, and `AppModelTests.swift` for manual sidebar reordering.
The local history showed no subsequent decoder/research commit or stash. This
establishes the scope of the unfinished diff, not which model authored it.

- The down arrow used an array index as SwiftUI's insertion offset, so moving
  down one row did nothing. Both arrows now use the same validated move path.
- Reordering was possible during export, whose requests resolve stack membership
  as the queue advances. It is now blocked at both the controls and model API.
- Reordering reconciles cached stack proposals synchronously. An intact ordered
  stack keeps its opt-in; changing its members' order clears that opt-in.
- A disabled stack could be immediately reloaded from its cached merged pixels.
  Loading a source now discards an aligned-stack cache entry without an enabled
  stack. The selected original is restored after a reorder or explicit disable.
- `scheduleRender` allocated/resized a sensor-size flat field before submitting
  every request. It now captures only an existing compatible buffer. Unity-field
  construction and resizing happen in the background CPU density path, preserving
  the old geometry and pixel arithmetic. Ordinary GPU edits need neither.

At 7752 × 5184, the removed unity allocation contains 120,559,104 UInt16 values:
**241,118,208 bytes per request** (about 230 MiB). Sixty requests would initialize
14.47 GB of buffers. This is arithmetic from source dimensions, not measured
memory traffic, allocation lifetime, or an achieved frame-rate improvement.

Validation: eight focused release tests passed in 0.385 seconds (the density
pixel test also ran with and without a real flat field). They cover arrow and
multi-row moves, boundaries, preserved selection, export exclusion, intact and
reordered stacks, explicit stack disable, rapid edits, and density geometry.
Compilation was capped at two jobs; no RAW corpus or performance loop was run.

Focused reproduction from the repository root (reuse the package's writable
module cache):

```sh
CLANG_MODULE_CACHE_PATH="$PWD/native/FilmScanEngine/.build/arm64-apple-macosx/release/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/native/FilmScanEngine/.build/arm64-apple-macosx/release/ModuleCache" \
swift test --disable-sandbox -c release --package-path native/FilmScanEngine \
  --jobs 2 --no-parallel \
  --filter 'moveSidebarFilesReordersAndPreservesSelection|sidebarExportStateTracksActiveAndPendingJobs|sidebarReorderReconcilesEnabledStack|deferredPreviewFlatFieldPreservesDensityPixels|actualRenderQueueDisplaysLatestUpdate|flatFieldChangesSubmitPreview|densityFlatFieldExport|selectAdjacentScanFollowsImportOrder'
```

## What the current code tells us

Paths below are under `native/FilmScanEngine/Sources/`.

| Finding | Source / symbol | Implication |
|---|---|---|
| Every edit saves the full settings dictionary as pretty-printed, sorted JSON using an atomic file write on the main actor. | `FilmScanConverterMac/AppModel.swift`: `updateParameters`, `saveParameters`, `persistSettings`; `PerFileSettingsStore.swift`: `save` | Work grows with saved history, including paths outside the currently open roll. In-memory test models usually omit this store. |
| Ordinary RAW preview sizes grow from draft to inspect to full sensor. The renderer uses the whole image extent. Standard images normally stay at 1000px. | `AppModel`: `applyPreviewSession`, `makeRawFullPreviewSession`; `FilmScanPreviewRenderer/StillPreviewRenderer.swift`: `render` | The same slider can become more expensive after the sharper RAW tier arrives. Fit-scale rendering does not currently reduce this workload. |
| Automatic crop, perspective, straighten, manual crop, or the measured-density flag prevent GPU rendering. | `AppModel`: `processRenderQueue` | Even a subsequent exposure edit on a cropped scan runs full-source CPU correction. |
| A completed render is discarded whenever another request is pending; publication also requires exact current parameters. | `AppModel`: `processRenderQueue` | If edits arrive faster than rendering, the image may stop updating until the drag pauses. A bounded queue prevents backlog, but does not guarantee visible progress. |
| Darkroom analysis is recomputed on each render; curve LUTs already have a small cache. | `StillPreviewRenderer`: `render`, `curveLUTImage` | Source/profile/paper analysis can potentially be reused across exposure, white balance, and wheel changes. |
| A full CGImage is produced, then drawn into a small CGContext for statistics, before publication. | `StillPreviewRenderer`: `render`, `statistics`; `AppModel`: `processRenderQueue` | Presentation and diagnostic work are part of latency beyond the correction kernel itself. |
| Full preview and lookahead are launched with `async let`; inspect and lookahead use detached decoders outside the full-preview/export gate. | `AppModel`: `schedulePreviewWork`, `decodeAndCacheRawInspect`, `decodeAndCachePreviewTier`, `RawFullPreviewDecodeGate` | The gate does not serialize every RAW decode. Bounded background work can contend with interactive work and with export. |
| A renderer adds an RGBA16 backing to the retained BGR16 source; cache byte accounting counts only source and analysis arrays. | `StillPreviewRenderer.init`; `CachedPreviewSession.byteCount`; `UInt16Image.rgba16Data` | The logical 256 MiB cache limit is not a bound on total retained image/graphics memory. |
| Preview CFA binning runs after the unpack timer and before the process timer. | `CLibRawShim/RawTherapeePipeline.cpp`: `fsc_decode_rawtherapee_direct`, `shrinkMosaicToBound` | The sum of decode stage timings omits binning. An external wall timer is necessary. |

These are observable control-flow and ownership facts. Their relative latency
and energy costs still need short measurements on the actual app.

## Editing: preferred sequence

### 1. Measure the complete interaction and move persistence out of it

Start a monotonic interaction timestamp in the control setter, before persistence
and request preparation. Record preparation, queue wait, CPU analysis, render,
statistics, publication, and actual presentation separately. The current
`submitTime` starts too late, and the “Frame Displayed” event marks assignment to
`previewImage`, not a screen presentation. Count the longest gap between frames
as well as median latency; measuring only successfully displayed frames hides
starvation during a drag.

Keep changes immediate in memory and coalesce durable writes on a serial worker.
Use immutable, versioned snapshots so an older write cannot overwrite newer
settings. Flush at gesture completion and graceful termination, and retain the
existing save-error reporting. Decide and document the maximum loss window on
an abrupt crash; deferring writes is not automatically equivalent durability.
Do not synchronously rewrite a growing JSON document at every slider tick.

First experiment: one small decoded image, a real temporary settings store, and
1/100/1000 stored paths. Compare setter duration and visible progress with the
same model configured without persistence. This isolates UI work without any
RAW decode. Gesture, undo/redo, selection changes, write failures, and relaunch
are the correctness checks for a subsequent implementation.

### 2. Render the visible resolution and keep geometry on the GPU

Retain the selected full-resolution source for inspection, but render a surface
sized for the viewport's backing pixels. At 100%, process the visible source
rectangle plus the needed sampling halo. Fit and zoom should select appropriate
resolution levels; a source-size upgrade must not multiply the work of a Fit
view. If a temporary lower-resolution drag surface is used, refine it after the
gesture without changing document dimensions or the viewport transform.

Core Image supports this architecture without replacing all existing correction
code. Apple recommends reducing the rendered pixel count in its
[Core Image performance guide](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/CoreImaging/ci_performance/ci_performance.html).
For this app, compare reducing the source before correction with scaling the
corrected graph: nonlinear correction and resampling do not commute. Keep
analysis tied to a stable source proxy so tone/color does not pump with zoom.

Move crop/rotation/straighten/perspective into the GPU graph in the same order as
the CPU reference. Start with the common manual-crop path, then exact geometry
mapping and matching border/interpolation behavior. Preserve sensor-space flat
fields, outward crop rounding, source-editor canvases, Original comparison, and
overlay alignment. Do not merely remove the CPU fallback conditions.

First experiment: replay an exposure drag on one retained source at draft,
inspect, and full sizes; repeat with a manual crop. Measure Fit and 100% with
background decode paused. Then enable background decode once to isolate
contention. Keep reference pixels and geometry tests; allow preview differences
only under the existing documented tolerance and separately assess resampling.

### 3. Present directly to a GPU surface and avoid diagnostic stalls

Prototype a demand-driven `MTKView` within the existing viewport model, with a
`CIRenderDestination` and a shared command queue for Core Image and presentation.
This removes the requirement to finish a full raster snapshot before handing
it to AppKit. Apple provides both
[render-destination sample code](https://developer.apple.com/documentation/coreimage/generating-an-animation-with-a-core-image-render-destination)
and [queue/presentation guidance](https://developer.apple.com/videos/play/wwdc2020/10008/).
The source currently uses `createCGImage`; actual readback/synchronization cost
should be measured, not inferred solely from that API name.

Compute diagnostics from a small render branch, less frequently during a drag,
and attach the result to the displayed revision. Do not let statistics hold up
presentation. Bound frames in flight and draw only on changes, rather than
burning GPU time while idle. Preserve a raster path for export, tests, and
contact sheets.

Study scheduler publication at the same time. A monotonic sequence of completed
frames can remain responsive even if newer edits are pending, provided frames
from old selections, source versions, or geometry never publish and the exact
final edit is guaranteed after release. That is an intentional revision of the
current strict stale-parameter policy and needs its own interaction tests.

### 4. Cache invariants, not entire changing renders

Memoize Darkroom analysis by immutable source identity plus resolved profile and
paper values. Exposure and wheels should reuse it; source upgrades and relevant
profile changes must invalidate it. Begin with a single-entry or small bounded
cache. This may be cheaper than the earlier sorting improvements because it
avoids the analysis entirely for many edits.

Keep explicit accounting for the UInt16 source, RGBA backing, optional GPU
textures, and output surfaces, avoiding double-counting aliases. Compare this
with physical footprint. Do not multiply every file by a full image pyramid.
Do not blindly toggle the shared context's `cacheIntermediates`: cache policy
depends on graph reuse and memory ownership. A still editor with an expensive
unchanging prefix has different reuse from a video stream.

## Decode: a Metal backend is plausible, but choose the seam

Keep LibRaw's file parsing, metadata, camera coverage, and compressed-mosaic
unpack initially. Its API deliberately exposes unpacked data and separate
postprocessing; a GPU developer backend can start after unpack rather than
reimplementing all of LibRaw. The current C++ shim already intercepts demosaic.
See the [LibRaw C++ API](https://www.libraw.org/docs/API-CXX.html).

There is concrete precedent: darktable's
[Markesteijn OpenCL kernels](https://raw.githubusercontent.com/darktable-org/darktable/master/data/kernels/demosaic_markesteijn.cl)
split green interpolation, directional reconstruction, and related work into GPU
stages. They use floating-point buffers and are not an exact replacement for
this repo's integer LibRaw oracle. They establish feasibility of the algorithm
family on GPUs, not a speed estimate or output-equivalence claim for Metal.

The difficult constraints are in this implementation:

- The 512px tiles overlap. Later tiles read writes from earlier neighbors,
  including above-right; `2 * row + column` wavefronts preserve those dependencies.
  One threadgroup per tile, all running independently, would repeat the already
  rejected overlapping-OpenMP mistake.
- One three-pass tile uses `512 * 512 * (8 * 11 + 6)` scratch bytes: **23.5 MiB**.
  A one-pass tile uses 12.5 MiB. These cannot fit in a GPU threadgroup's local
  memory. Apple's [Metal capability tables](https://developer.apple.com/metal/capabilities/)
  list 32 KiB of threadgroup memory for the relevant Apple GPU families. Use
  device-memory scratch, smaller spatial workgroups, and explicit stage/diagonal
  dependencies; derive the halo before changing tile organization.
- Exact output includes integer shifts, clipping, pass order, tie-breaking, Lab
  calculations, and floating-point comparison results. Float contraction and
  changed evaluation order can alter later discrete decisions. “Same named
  algorithm” does not imply equal pixels.
- A fast GPU demosaic that immediately hands data back to CPU postprocessing
  saves only that stage. The larger opportunity is an eventual GPU-resident
  develop/edit graph, with one intentional CPU boundary for export if needed.
  The current bridge returns encoded sRGB UInt16 BGR, not sensor-linear RGB;
  changing that contract requires corresponding downstream changes.

Run two distinct research tracks:

| Track | First experiment | Promotion condition |
|---|---|---|
| Preserve the final decode oracle | Optimize one measured serial/independent stage or prototype one Metal stage against stored boundary data. CPU SIMD, scratch reuse, and less conservative dependency scheduling are candidates, not assumed wins. | Exact stage and output hashes, bounded memory, cancellation, and a meaningful end-to-end improvement. |
| Faster interactive demosaic | A separate one-pass Metal preview backend, initially for the known X-Trans camera, with CPU unpack and fallback. | Film-grain, edges, false color, moiré, highlights, and negative-inversion quality are acceptable; edit latency and energy improve. Keep final export unchanged. |

For the exact CPU track, an asynchronous tile dependency graph could remove
whole-diagonal barriers while retaining every actual predecessor. First map all
reads/writes, including the sequential green initialization; release a tile only
after its true dependencies finish. This may help irregular edge tiles, but it
cannot remove the inherent critical path and could lose to scheduling overhead.

Three less ambitious directions deserve measurement before a large port:

1. **One selected-file unpack session across preview tiers.** Draft, inspect,
   full preview, and first export currently create separate decoders and unpack
   again. An immutable mosaic plus metadata could avoid repeated unpack. Budget
   roughly 80 MB for a 40 MP UInt16 mosaic, plus real margins and any required
   work buffers. `shrinkMosaicToBound` overwrites the mosaic and size metadata,
   so reusing its mutated decoder is invalid. Preserve a pristine source and
   isolate each processing pass; release on selection change. The already-fast
   Fuji unpack limits the possible saving.
2. **Demand and priority.** Defer full-sensor work while the user is dragging or
   browsing rapidly, and prioritize selected work over speculative lookahead.
   Detached tasks do not automatically inherit their parent's cancellation.
   Thread a cancellation token through the shim and check safe wavefront/strip
   boundaries. LibRaw has a progress callback, but the custom interpolation body
   also needs explicit checks. Keep one authoritative decode in flight.
3. **Account for binning and copies.** Time CFA shrink explicitly, then inspect
   its scalar traversal and cache behavior. Optimize independent tiles or SIMD
   only after measuring it. The camera-scan path also calls
   `dcraw_make_mem_image`, followed by a Swift copy/swizzle. LibRaw's
   `copy_mem_image` can target caller storage; investigate this boundary without
   assuming that eliminating a copy buys 20% overall.

An alternative worth a bounded comparison is Apple's `CIRAWFilter`. Apple
announced RAW 9 for macOS 27, using neural demosaic/denoise, and demonstrated an
X-T5 example. It requires runtime version/model checks and is more resource
intensive on the first render. It is neither a macOS 14 baseline nor compatible
with the frozen decode; automatic denoising also needs careful film-grain
assessment. Treat it as an optional quality/performance comparator, not a silent
backend switch. [Apple's RAW 9 session](https://developer.apple.com/videos/play/wwdc2026/305/)

For scale, if demosaic accounts for fraction `f` of matched decode wall time and
becomes `s` times faster, total time becomes `1 - f + f/s` of the original.
At an illustrative `f = 0.70`, a 2× demosaic yields 35% less decode time;
eliminating a 5% copy yields at most 5%. Neither fraction is newly measured here.
If “25% slower than Camera Raw” means `ours = 1.25 * theirs`, parity requires
a 20% reduction in our time. Compare first corrected paint, full-detail-ready,
and final-quality decode separately before translating the owner's estimate
into an engineering target.

## Export: optimize the actual remaining stage

The selected RAW already retains one three-pass decode for settings-only
re-export. TIFF/PNG already use compact RGB16 packing; JPEG uses RGB8. SIMD and
parallel packing work has already been done. These are not new opportunities.
The dated [export report](40mp-export.md) separates these changes and explains
why old LZW timings must not be presented as default uncompressed-TIFF latency.

First split cold export from retained-decode re-export, with default TIFF and
the same correction/geometry. Re-export reveals CPU correction and writer costs
without demosaic. Measure PNG, JPEG, LZW TIFF, and processed DNG separately only
when investigating those formats.

For correction, investigate caching source-derived analysis and processing in
row bands with reusable scratch. Some linear paths expand to three Double
channels—about 964 MB at 40.19 MP for a single full-frame buffer. A tiled design
must compute global statistics once and preserve sampling, nonlinear stage
order, quantization boundaries, geometry halos, and border behavior. Replacing
Double with Float or fusing operations is not automatically byte-preserving.

A GPU export correction path could share more code with the preview, but the
existing 2/255 preview tolerance does not establish 16-bit export correctness.
Establish a separate accepted output contract before using preview kernels for
final files. Keep the CPU path as oracle and fallback.

For writer-bound formats, evaluate bounded strip/tile production and packing
directly into the writer's layout. Start with the existing ImageIO writer; a
custom encoder only makes sense if it wins enough to justify color metadata,
independent-reader, cancellation, and staged-file cleanup work. Do not add a
second full-resolution RAW decode to hide write time. Pipeline overlap has an
energy/memory cost and is a later experiment with explicit bounds.

## Small experiments and decision gates

Use one short release trace on a retained image before rebuilding decoder work.
Run expensive corpus checks only when a candidate changes pixels or scheduling
at those boundaries.

| Priority | Experiment | Decision evidence |
|---|---|---|
| 1 | Real settings-store drag, then draft/inspect/full at Fit and 100%, crop off/on | Setter time, longest no-frame interval, presented-frame latency; establish whether UI work, render size, or CPU fallback dominates. |
| 2 | Source/profile analysis reuse and bounded display surface | Reuse hit count, frame cadence, final exact edit, stable tone through zoom/source upgrades. |
| 3 | GPU geometry and direct drawable presentation | Correct overlays and crop pixels, presentation latency, bounded frames/surfaces, idle energy. |
| 4 | Decode wall/stage trace with background work disabled/enabled | Account for binning and queue contention before changing interpolation. |
| 5 | One isolated Metal demosaic stage or independent CPU stage | Correct boundary output, measured speed and scratch size; stop if the benefit disappears after transfers/postprocessing. |
| 6 | Default-TIFF cold/re-export split, then one writer-specific candidate | Same format/settings, CPU correction time, pack/finalize time, output readability and hashes. |

Capture machine, OS, toolchain, source revision/dirty state, input hash, decode
quality, worker counts, source/output dimensions, zoom/backing scale, power mode,
and active background jobs. Start with three short alternating A/B repetitions;
do not label three samples a reliable tail-latency estimate. Record raw samples.
Measure physical footprint and energy per completed operation as well as wall
time; faster full-power work does not necessarily use less battery.

For RAW changes, the repo's existing five-repeat stage/output determinism gate
and serial worker oracle still apply before promotion. A small smoke test can
reject a bad idea cheaply; it cannot certify an altered interpolator. The
40 MP CPU/GPU comparator, full RAW corpus, and format matrix were intentionally
not run for this source investigation.
