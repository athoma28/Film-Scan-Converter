# Further native performance opportunities — October 2, 2026

The later [implementation report](implementation-2026-10-02.md) records the
authorized follow-through. This document preserves the earlier discovery state
and rejected packing experiment.

Four concurrent reviewers inspected the pre-implementation native working tree:
CPU processing, preview scheduling, RAW/export I/O, and measurement/integration.
The strongest candidates at discovery were exact density-print lookup, thumbnail
work outside the main actor, fewer dust morphology passes, and removal of
redundant stack I/O. Inspection established **source-confirmed opportunities,
not measured speedups**; the later report supplies implementation evidence.

One bounded RGBA8 packing experiment was built and measured. Its proposed
parallel implementation regressed small previews and did not reliably improve
full-size color previews, so it was rejected. **No packing-candidate code was
retained in this discovery pass.** Existing working-tree changes, color defaults,
and preferred looks remained untouched by discovery.

## Follow-through status

The six ranked items below were implemented later on October 2. Their original
source descriptions, line locations and “Next” instructions describe the frozen
discovery baseline, not the current source. Use the
[implementation report](implementation-2026-10-02.md) and
[performance index](index.md#measurement-questions-still-open) for completed
checks and current measurement questions.

| Discovery item | Later status | Remaining evidence limit |
|---|---|---|
| Exact density-print input lookup | Implemented; exhaustive exactness and matched CPU correction checks | Bounded one-RAW cohort; not a total export/GPU speedup |
| Worker thumbnails/shared RAW dimensions | Implemented; output/isolation tests and eight-file metadata probe | Main-actor/import latency, rotated sources and metadata-error cohort unmeasured |
| Combined dust closing/queue reuse | Implemented; production oracles and complete synthetic masks match | Real-scan quality and repair throughput unmeasured; individual changes not timed separately |
| Resident stack reference | Implemented; pixel/cleanup guards and bounded stack probe | Logical I/O saving; no physical-disk reduction or general throughput claim |
| Bounded DNG packing | Implemented; identical bytes/cleanup and first-write peak evidence | Throughput variable; settled app-memory benefit not established |
| Skip invalidated render stages | Implemented; scheduling/publication tests | Wasted-stage counts and navigation latency unmeasured |

## Ranked experiments at discovery

### 1. Exact input lookup for CPU density printing

[`DensityPrintProcessing.pixelDensities`](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/FilmScanEngine/DensityPrintProcessing.swift)
around line 339 repeatedly converts each UInt16 channel to linear light and
computes its logarithm. This is three logarithms and up to three transfer-function
powers per pixel, before the image-dependent matrix and print response. Current
C-41/cyan CPU rendering uses this path; the September 28 measurements established
no improvement for those cases. Supported Metal previews have a different path.

A single immutable Double table of `log10(max(sRGBToLinear(code / 65535), epsilon))`
over all 65,536 codes would occupy **512 KiB** of element storage. It can remove
repeated scalar work without reducing the input precision. Keep the subsequent
matrix and arithmetic order unchanged. The existing Float table is not an exact
substitute. Exhaustive Double bit-pattern equivalence remains to be demonstrated
in the production release build; it is not established by this inspection.

Next: compare all input-code bit patterns, table initialization cost, and cold/warm
C-41/cyan runs with the existing CPU point-work probe. Freeze baseline/candidate
executables, require matching complete output hashes, and bracket timings. Then
run the applicable processing/parity/preference checks before retaining an engine
change. Preparing settings-only print-response terms is a separate follow-up;
inspect optimized code before claiming those calculations survive compilation.

### 2. Prepare sidebar thumbnail bitmaps on a worker and reuse their context

The decode is already detached, but
[`AppModel.publishSidebarScanAnalysis`](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/FilmScanConverterMac/AppModel.swift)
around line 4188 calls bitmap packing and inversion on the main actor.
[`PreviewBitmap.invertedNSImage`](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/FilmScanConverterMac/RasterImage.swift)
constructs a new `CIContext` and synchronously renders each thumbnail.

Prepare the original/inverted CGImages on the existing utility worker using a
dedicated reusable context; keep NSImage creation and publication on the main
actor. Preserve named-sRGB output, complement behavior, cancellation, and stale
selection guards. Measure cold import while editing, including main-actor blocked
time and selected-preview latency. `RasterImageTests` and sidebar app checks
provide output guards. No cold-import latency reduction is claimed yet.

A related, separable change removes duplicate RAW metadata work:
`makeSidebarScanAnalysis` around line 5254 extracts the embedded thumbnail and
then opens the same RAW again for full-resolution dimensions.
[`CLibRawShim.c`](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/CLibRawShim/CLibRawShim.c)
has separate open paths in `fsc_extract_thumbnail` and `fsc_raw_full_dimensions`.
Sharing optional dimensions must retain legacy sensor geometry,
`half_size = 0`, `adjust_sizes_info_only`, and orientation handling. A failed
dimension lookup must not invalidate an otherwise valid thumbnail. Count opens
and verify thumbnail hashes/dimensions on a mixed-orientation import before
measuring gains. Embedded JPEG dimensions are not a replacement.

### 3. Collapse repeated dust morphology and remove duplicate component storage

[`DustDetection.swift`](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/FilmScanEngine/DustDetection.swift)
around line 77 applies five square dilations, followed by five square erosions,
at the default closing count when the kernel is active. Every pass rebuilds an
Int integral image. Combining each repeated operation into one effective-radius
operation could reduce **ten closing passes to two**; the later component-filter
dilation is separate and must remain. Handle effective-radius overflow and retain
the current clipped, neutral border treatment.

An independent Python oracle passed **319,440 comparisons across 1,354 input/shape
cases**, including exhaustive tiny masks, borders, even/odd and oversized kernels,
and zero iterations. The correct effective radius is
`iterations * (kernelSize / 2)` with integer division. This verifies the composition
in independent logic; a production Swift candidate and complete detector output
still need validation. The common `iterations * (kernelSize - 1) + 1` kernel formula
fails for even nominal kernels, although production currently generates odd ones.

Detection in the app is bounded at 2,048px. At 2048 × 1365 the integral array is
about **21.4 MiB per pass**, reused sequentially; eliminating passes is not a
tenfold reduction in peak memory. Next: check Swift equivalence, frozen OpenCV
fixtures and complete detector masks, and benchmark the bounded detector.
This targets detection, not texture repair or export throughput.

`retainSmallComponents`, around line 184, also stores the same BFS traversal in
both `queue` and `component`. Reusing the finished queue removes one append per
component pixel and one redundant Int array. The worst-case raw element saving
at 2048 × 1365 is about **21.3 MiB**, depending on foreground occupancy. Preserve
contour ordering and exact mask output. This is a smaller independent patch.

### 4. Avoid spooling the already-resident stack reference

[`StoredScanStack.append`](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/FilmScanEngine/StoredScanStack.swift)
retains the first image's pixels, writes them to a temporary file, and later
rereads them for every merge band while the original reference remains resident.
Use that immutable reference directly and spool only subsequent captures.

For a 7,752 × 5,184 RGB16 source, this removes **241,118,208 requested write bytes
and the same number of read bytes: about 460 MiB per stack**. These are logical
I/O bytes, not measured physical disk traffic or an export speedup. Registration
and RAW decoding are unaffected. Explicit Data-to-array and output-band copies
are separate follow-ups; their actual allocation/copy costs need profiling.

Measure append/register and finish/merge independently for translated HDR and
noise-reduction stacks. Preserve source indexing, short-read failures, row edges,
cancellation, and temporary-file cleanup. Existing stored-band/original-merge
parity tests provide a numerical oracle. This serves full-resolution stack
preview/export; in-memory contact sheets use another path.

### 5. Stream DNG packing with a bounded buffer

[`UInt16Image+DNG.swift`](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/FilmScanEngine/UInt16Image%2BDNG.swift)
currently creates a complete packed strip while retaining the source image.
The exact transfer table and parallel packing already exist. Generate the same
single-strip byte stream in bands, preserving the current header and staged
commit rather than changing the image format.

For a 7,752 × 5,184 RGB16 source, a 16 MiB band could replace approximately
230 MiB of full-strip storage,
reducing logical packed backing by about **214 MiB**. More writes could cost time;
physical footprint and throughput must both be measured. Require identical file
hashes, independent-reader agreement, final partial-band coverage, and failure
cleanup. Keep the existing total-packed-byte metric distinct from maximum live
buffer size. TIFF/JPEG/PNG and RAW decode would be unaffected.

### 6. Stop obsolete render work between expensive stages

[`AppModel`](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/FilmScanEngine/Sources/FilmScanConverterMac/AppModel.swift)
around lines 4924–5017 finishes its detached rendering worker before rejecting a
stale generation. `cancelRenderLoop` around line 5132 advances that generation
without stopping subsequent overview/detail or correction/packing stages.
Context-bound invalidation checks could avoid obsolete work after source or
geometry changes while retaining one draining worker. Ordinary point edits must
keep their existing useful intermediate-publication behavior.

Measure wasted-stage counts and latest-preview latency during rapid navigation
through CPU fallback cases. Do not introduce overlapping full-source workers.
This is a scheduling change with more correctness risk than the local candidates
above, and no wasted-time measurement has been made.

## Lower-priority or constrained directions

- **Retain CPU preparation across cached revisits.** Assigning `previewSource`
  creates a new CPU preparation cache even when revisiting a retained session.
  A subsequent point edit can rebuild full straighten/perspective geometry.
  Retaining that preparation trades recomputation for potentially hundreds of
  MiB per session; charge it to the existing LRU and measure first-edit latency
  and footprint. September 27/28 timings warmed and excluded the first warp.
- **Parallel initial photographic conversion.** The initial non-density branch
  is still serial. This was already identified September 28. Check release
  code and repeated band-dispatch overhead before treating it as a new priority.
- **Keep native resource contracts.** No next-file RAW export prefetch,
  concurrent contact-sheet decoding, forced overlapping-tile OpenMP, lower final
  resolution, or changes to film defaults are proposed.

## Measured and rejected: straightforward parallel RGBA8 packing

The candidate replaced the serial contiguous unsafe-buffer loop with bounded
disjoint ranges using the existing export worker limit: at most eight workers
for images with at least 100,000 pixels. Smaller inputs invoked one closure
directly. It retained
integer `>> 8`, RGB reordering, and alpha 255. It also changed source access to
captured Array indexing, which may inhibit optimization; the experiment does
**not** establish that every possible parallel implementation would lose.

Both arms were linked from freshly built ordinary production release engine
objects. A frozen baseline ran first, followed by a frozen candidate and the same
baseline executable again, with no concurrent native builds/tests. Each case had
one warmup and seven measured constructions. Input channels are deterministic
UInt16 code permutations. No RAW decode, color correction, or disk image output
was involved.

| Synthetic construction | Baseline median ms | Candidate median ms | Baseline recheck median ms |
|---|---:|---:|---:|
| 256 × 171, gray | 0.0098 | 0.0442 | 0.0058 |
| 256 × 171, color | 0.0095 | 0.0589 | 0.0062 |
| 2048 × 1370, gray | 0.255 | 0.440 | 0.178 |
| 2048 × 1370, color | 0.332 | 0.440 | 0.271 |
| 7752 × 5184, gray | 11.421 | 8.804 | 9.569 |
| 7752 × 5184, color | 12.435 | 11.444 | 10.116 |

The timer covers synchronous `makePreviewCGImage`: destination allocation,
packing, and provider/CGImage construction. Provider-byte extraction, SHA-256,
cleanup, AppModel publication, rendering, and screen presentation are outside
timing. All **126 recorded outputs** have matching hashes within their six
corresponding workloads across the three runs. Seven observations are not a
population-tail estimate. Background applications were not controlled, and the
baseline drift limits attribution. Small-input regressions and the full-color
recheck are sufficient to reject this implementation despite the gray result.

Environment: Apple M4 Pro (Mac16,7), 14 cores, 48 GB RAM, macOS 15.7.9,
Swift 6.1.2. About 29 GiB of disk space was available before collection. Source
baseline: `2b4da0930df3ccebc08c1e3197a8ec242df448ac` plus pre-existing local work.

## Evidence and verification limits

Ignored `dist/performance-discovery-2026-10-02/`
contains source/object/binary hashes, build logs, the frozen executables,
`PackingProbe.swift`, link helper, raw samples, the rejected source, and the three
agents' audits. `comparison.json` retains the three-arm comparison and
`final-verification.json` records restoration. These are local artifacts with
the [index's availability limits](index.md#evidence-availability-and-provenance).
The candidate's proposed regression tests are archived there;
they were **not run or retained in the test suite**. Cross-arm hash comparison
and restoration checks passed. All production source files recorded in the
baseline manifest match after restoration.

The CPU audit includes the independent morphology oracle, its source fingerprint,
and passing result JSON. It is algorithmic evidence, not a native test or timing
benchmark. Its short run finished before the candidate packing timing process.

No full native suite, CPU/Metal comparator, RAW compatibility run, photographic
preference render, export benchmark, or native interaction replay was rerun.
These are unnecessary to claim discovery and rejection; their historical passes
are not presented as fresh verification. Production baseline and candidate builds
succeeded. The production app rebuild after restoration also succeeded (31.28 s),
so its build output matches the unchanged source again.
