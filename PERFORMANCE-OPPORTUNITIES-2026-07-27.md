# Full-Resolution RAW Decode And Export Performance

**Status:** Closed full-resolution export-latency guide; threaded boundary
isolated 2026-07-30; adjusted-correction evidence completed 2026-08-03;
adjusted-correction repair completed 2026-08-12; deterministic X-Trans repair
completed 2026-08-12; deterministic X-Trans wavefront follow-up completed
2026-08-13; parallel Fuji unpack completed 2026-08-14 as roadmap item 5
slice 1. Remaining inspect/re-export work (last-decode retention) landed on
2026-08-30 as roadmap item 5 slice 3. Mosaic-binned RAW browsing
is complete.

**Date:** 2026-07-27  
**Production baseline:** `main` at `3d8456f`, plus the measurements in
`docs/performance/40mp-export.md`  
**Scope:** Native full-resolution RAW decode, correction, geometry, packing,
and export. Interactive preview and the legacy Python application are out of
scope.

This document replaces the original static-analysis memo. The original found
important hotspots, but it mixed committed and uncommitted source, treated
engineering estimates as likely savings, and made incorrect claims about
LibRaw threading, determinism, fixtures, TIFF defaults, and batch memory.
This version records what is measured, what is inferred, and what must be
proven before an optimization can ship.

## Executive Decision

The two measured areas have completed bounded repairs:

1. **Final-quality X-Trans decode had a safe parallel seam.** LibRaw's
   overlapping OpenMP tiles remain disabled. Work inside each tile stays
   serial; independent `2*row+col` wavefront diagonals run across at most
   eight workers so the 16-pixel halo, including the above-right neighbor,
   stays ordered. Five release repetitions reproduced all eight approved
   stage/output digests. Warm demosaic fell from the stock 12.72–12.77-second
   range to 3.38–3.54 seconds in the 2026-08-12 row-parallel repair and to
   2.85–2.86 seconds in the 2026-08-13 wavefront follow-up.
2. **Adjusted full-resolution correction had avoidable passes and allocations.**
   The 2026-08-12 in-place parallel repair preserved every scenario digest,
   reduced the adjusted-path peak from 1.984 GB to 1.017 GB, and materially
   reduced all four adjusted scenario intervals.

This page remains the evidence record for that closed slice. Do **not** reopen
it as an unrestricted rewrite, a RawTherapee X-Trans port, a TIFF dependency,
or batch prefetch. Last-decode retention landed on 2026-08-30 as product-roadmap
item 5 slice 3. Mosaic-binned RAW browsing and parallel Fuji unpack have landed.

## Evidence Rules

The labels below are deliberate:

- **Committed measurement:** repeatable result already recorded in
  `docs/performance/40mp-export.md`.
- **Audit measurement:** result from the isolated 2026-07-27 experiment
  described below. It is not a production benchmark or a universal hardware
  claim.
- **Source fact:** directly visible in the current implementation or upstream
  source.
- **Hypothesis:** plausible but unmeasured; it must not appear in release notes
  or acceptance criteria as a promised saving.

The original memo claimed to describe `main` at `3d8456f`, but some references
actually described the dirty 2026-07-27 working tree. In particular,
`PerspectiveWarp.swift` and writer staging had uncommitted changes. Future
reports must record both `git rev-parse HEAD` and `git status --short`, and must
state whether line references describe HEAD or the working tree.

## Measured Baseline

The committed M4 Pro / Mac16,7 release benchmark for the 40.19 MP
`DSCF0669.RAF` records:

| Stage | Representative p50 | Meaning |
|---|---:|---|
| Total RAF to LZW TIFF | 24.789 s | LZW is explicitly selected by the benchmark |
| Full-resolution decode | 21.677 s | Dominant stage |
| Sensor unpack | 1.342 s | Initial decomposed smoke result |
| Three-pass X-Trans demosaic | 19.710 s | 90.9% of decode |
| LibRaw post-process | 0.378 s | Small |
| ISO-adaptive policy | 0.137 s | Small |
| Swift copy/swizzle | 0.049 s | Small |
| Neutral fused correction | 0.764 s | Does not represent adjusted exports |
| LZW TIFF writer | 2.286 s | Format/compression-specific |
| PNG writer | 5.139 s | Format-specific |
| DNG writer | 0.053 s | Leaves little writer work to hide |

TIFF compression in the application defaults to `.none`. The LZW numbers above
describe a selected compression mode because `FilmScanExportBenchmark`
explicitly requests LZW; they are not the default TIFF cost.

The later `DSCF2833.RAF` correction-scenario matrix isolates the adjusted stage
on the same 40.19 MP class: neutral, tone, protected-color, dye-mixing, and
combined medians were 0.105, 2.182, 2.266, 1.885, and 2.749 seconds. All
scenario hashes repeated across three samples, all temporary TIFFs were
removed, and post-scenario physical footprint returned to 47.3–54.2 MB despite
the 1.984 GB process-lifetime peak. See `docs/performance/40mp-export.md` for
the command, p95 values, and fixture contract.

## Audit Measurement: Existing LibRaw OpenMP

### Why this was tested

LibRaw 0.21.4 already contains tiled OpenMP X-Trans demosaic code. On Apple
platforms its headers undefine `LIBRAW_USE_OPENMP` unless
`LIBRAW_FORCE_OPENMP` is defined. The installed Homebrew
`libraw_r.23.dylib` linked `libomp`, but did not contain the expected OpenMP
runtime call sites, so linking `libomp` alone did not make the hot path
parallel.

The camera-scan path also calls LibRaw's `open_file`; it returns before the
compatibility shim's mmap path. The original memo's claim that camera-scan
unpack was already mmap-backed was incorrect.

### Experiment

An isolated LibRaw 0.21.4 was compiled with OpenMP and
`-DLIBRAW_FORCE_OPENMP`. The release `FilmScanExportBenchmark` was linked
against that library and run on `sample-raw/fuji400-fresh/DSCF2833.RAF`, one
processed-DNG repetition, using the same application source.

| Build | Threads | Unpack | Demosaic | Decode | Total | Output |
|---|---:|---:|---:|---:|---:|---|
| Homebrew LibRaw | stock | 0.8920 s | 13.1796 s | 14.5411 s | 14.7358 s | Stable reference |
| Forced-OpenMP LibRaw | 1 | 0.8470 s | 11.6314 s | 12.8970 s | 13.0666 s | Byte-identical to stock |
| Forced-OpenMP LibRaw | 14, run A | 0.1289 s | 1.3839 s | 1.9002 s | 2.1643 s | Different from reference |
| Forced-OpenMP LibRaw | 14, run B | 0.1081 s | 1.3817 s | 1.9324 s | 2.0973 s | Different from reference and run A |

The multi-threaded candidate was about 9.5× faster in demosaic, 7.6× faster in
decode, and 6.9× faster end to end for this DNG workload. It also accelerated
Fuji unpack, disproving the original recommendation to accept unpack as a
fixed 1.3-second floor.

The result **cannot ship**: the two multi-threaded runs did not produce the
same output hash. The experiment does not yet identify whether nondeterminism
originates in threaded unpack, X-Trans demosaic, another OpenMP path, or more
than one stage. The one-thread forced build matching stock is useful evidence
that the build itself did not intentionally select a different serial
algorithm.

### Required follow-up

Add hashes or stable comparisons at these boundaries:

1. unpacked mosaic plus dimensions/CFA metadata;
2. the LibRaw image inside the X-Trans callback immediately after
   `xtrans_interpolate` returns, before the remaining `dcraw_process` stages;
3. the processed LibRaw image returned by `dcraw_make_mem_image`, before ISO
   filtering;
4. post-ISO image;
5. Swift-owned `UInt16Image`;
6. packed writer input and final output.

Run each candidate at 1, 2, 4, 8, 10, and 14 threads, with at least five
repetitions per count. Use multiple X-Trans files, including the committed
40.19 MP benchmark input. Record physical footprint, not just RSS.

Only after locating the first divergent boundary should a developer choose
among:

- fixing or constraining LibRaw's existing threaded implementation;
- deterministic tiling of LibRaw's current integer algorithm;
- contributing an upstream fix and pinning the corrected dependency;
- accepting a documented numeric tolerance instead of exactness, which
  requires an explicit product decision and visual qualification.

RawTherapee's current X-Trans implementation is useful reference material, but
it is not the default solution. It uses different implementation details and
floating-point arithmetic, so a claim of byte identity with LibRaw's current
integer path would require proof. X-Trans passes are sequential at the
algorithm level; later work consumes values produced earlier. Do not schedule
the three passes concurrently on the assumption that they are independent.
Do not reduce final-quality export from three passes to one.

## Revised Work Plan

### P0 — Establish production gates and diagnose RAW threading — Completed 2026-08-12

This is the first work to land.

1. Extend `FilmScanExportBenchmark` with a camera-scan determinism mode that
   repeats the same decode and reports the stage-boundary evidence above.
2. Add a full-resolution camera-scan regression fixture. Existing
   camera-scan tests verify dimensions, profile flags, timings, and quality
   thresholds; the exact full-output reference currently covers the
   `rawPyCompatibility` profile instead.
3. Reproduce the forced-OpenMP result through a documented build, not an
   implicit Homebrew machine state — diagnostic reproduction completed
   2026-07-30 with a pinned LibRaw 0.21.4 source archive and isolated
   application link. The unpacked mosaic stayed exact at every worker count;
   the first changed boundary was tiled X-Trans demosaic. No custom library
   was adopted. If the application ships one later, packaging, notices, load
   paths, and clean-Mac validation remain part of the same change.
4. Locate and remove the first nondeterministic boundary — completed
   2026-08-12, with a 2026-08-13 wavefront follow-up. Rather than enabling
   LibRaw's overlapping OpenMP tiles, the shim keeps serial work inside each
   tile and the true overlap dependence, including the 16-pixel halo that can
   read the above-right neighbor. Independent `2*row+col` wavefront diagonals
   run across at most eight workers. The committed demosaic and final pixels
   remain exact across five eight-worker repetitions, and `FSC_XTRANS_WORKERS=1`
   still matches that oracle.
5. Re-run the documented three-repetition 40 MP format matrix and ten-file
   memory/cancellation checks — completed 2026-08-12. All 18 format-matrix
   outputs and all ten sequential TIFF outputs were removed, engine footprint
   stayed bounded, the ten-job app path completed without error, and active
   decode cancellation left no output.

Acceptance:

- final-quality three-pass camera-scan pixels remain exact, unless a separately
  approved tolerance contract replaces exactness;
- at least five repeated parallel decodes per fixture agree;
- cancellation and failure leave no apparent-success output;
- no sustained physical-footprint growth;
- one authoritative full-resolution RAW remains in flight;
- packaged-app dependency closure still passes.

No custom LibRaw library or new packaged dependency was adopted. The isolated
6.9× OpenMP result remains historical opportunity evidence, not a shipped
claim; the production wavefront measurements are recorded separately.

### P1 — Measure and repair adjusted full-resolution correction

`Processing.correctedPreviewPowerLaw` uses the compact parallel fused path only
when the relevant tone, protected-color, and dye-mixing adjustments are
neutral. Adjusted exports pass through serial work including:

- `powerLawRenderReadyLinear` and `renderPowerLawDisplay` in
  `FilmNegativeProcessing.swift`;
- tone, dye-mixing, and protected-color operations in
  `RenderReadyLinearImage.swift`;
- for the calibrated-color seam, additional `UInt16` to `Double` and back
  conversion in `Processing.swift`.

The structural problem and current latency are now measured and repaired. The
2026-08-12 implementation slice converted the serial full-frame `Double` seam
to in-place parallel operators, and the size of the achieved saving is now
recorded against the committed scenario fixture.

Implementation order:

1. Add benchmark scenarios for neutral correction, tone adjustment, protected
   color, dye mixing, and a representative combined adjustment. Report each
   pass, allocations, physical footprint, and output hash — completed
   2026-08-03 with three release repetitions, exact repeated hashes, cleanup
   checks, a committed full-resolution fixture, and documented memory evidence.
2. Remove avoidable full-frame allocations using in-place variants where
   ownership permits — completed 2026-08-12. `RenderReadyLinearImage` gained
   mutating `applyLinearToneAdjustments` and `applyProtectedColorAdjustments`,
   and `Processing`'s calibrated-color, power-law, and density seams now apply
   tone, dye mixing, and protected color on one buffer instead of reallocating
   a second scene-linear frame per pass.
3. Fuse adjacent per-pixel operations when that removes a material pass without
   obscuring the reference math — subsumed by step 2: the tone and color passes
   now write through one buffer, so no intermediate copy separates them.
4. Parallelize remaining independent rows/pixels and sweep worker counts —
   completed 2026-08-12. Tone, protected color, dye mixing,
   `powerLawRenderReadyLinear`, `renderPowerLawDisplay`, and the
   calibrated-color `UInt16`↔`Double` conversion passes all use disjoint
   per-pixel ranges over at most eight workers above the one-megapixel
   threshold, and each output element is written by exactly one worker.
5. Consider `Float`, structure-of-arrays, vDSP, or vForce only as separately
   measured candidates. Numeric changes require a rounding/tolerance contract
   and visual qualification.

The 2026-08-12 release `--corrections` run measured the adjusted-scenario
process-lifetime peak physical footprint at 1.017 GB, down from the 1.984 GB
baseline, and the committed corrected-image digests still reproduce
byte-for-byte. The measured correction-stage medians (tone 0.954 s, protected
color 0.993 s, dye mixing 0.944 s, combined 1.269 s versus 2.182/2.266/1.885/
2.749 s) came from a run whose decode slowed to 21.5–22.5 s from the
14.3–14.9 s baseline, so the latencies are directional while the
peak-footprint and byte-identity results are machine-independent. `Float`,
structure-of-arrays, vDSP, and vForce were not adopted; they remain separate
candidates only if profiling later justifies them.

Do not assume `vForce.vvpow` is a drop-in improvement. The current fast kernel
is fused and interleaved; materializing bases/exponents for a vector API may
add passes and memory traffic that outweigh arithmetic savings.

Acceptance:

- every adjustment scenario has a committed before/after result;
- neutral and adjusted output contracts remain explicit;
- physical footprint is measured with Mach physical-footprint metrics;
- no claim that parallelism alone removes the 965 MB buffer—allocation removal,
  in-place operation, fusion, or a narrower type must do that.

### P2 — Re-measure conditional throughput work

#### Writers

ImageIO's LZW TIFF and 16-bit PNG writers are legitimate conditional
bottlenecks. First measure how often those formats are used and establish the
uncompressed TIFF floor. The default app TIFF is uncompressed.

A libtiff or alternate-deflate dependency is justified only if:

- selected LZW/PNG use is important enough to affect the workflow;
- output metadata, ICC behavior, reopen compatibility, atomic staging, and
  packaging are qualified;
- changed encoded bytes are deliberately accepted while decoded pixels remain
  correct.

JPEG and DNG writers are already too small to justify special work.

#### Batch overlap

The current app requests file N+1 only after file N finishes export, so a
lookahead pipeline is architecturally possible. Defer it until decode and
correction costs settle:

- a fast all-core decoder may leave no CPU capacity for a concurrent writer;
- default uncompressed TIFF and DNG offer little writer time to hide;
- two active synchronous stages change cancellation and resource ownership;
- `safeParallelImageCount()` currently returns two, not one, on an 8 GB
  machine and does not account for the adjusted path's large `Double`
  intermediates.

Any later pipeline needs a stage-aware byte budget, format-specific benchmark,
and explicit cancellation behavior. Do not reuse the current decoded-image
count heuristic as proof of safety.

### P3 — Add Bayer evidence before optimizing RCD

The custom RCD path is serial and is likely worth parallelizing for Bayer
cameras. It is not presently justified as equal priority to X-Trans:

- the measured corpus is X-Trans;
- there is no committed real Bayer RAW fixture;
- no RCD stage timing or user-frequency evidence was recorded.

First add a legally usable Bayer fixture, an exact or explicitly tolerant
camera-scan contract, and decomposed timing. Then try conservative row/stage
parallelism with barriers before porting another implementation. Compiler
output must be inspected before pursuing source-level reciprocal, lambda, or
bit-shift micro-optimizations; constant divisions and small lambdas may already
be optimized.

### P4 — Profile-gated cleanup

These are real but small or conditional:

- ISO filter row/channel layout;
- Swift BGR-to-RGB copy/swizzle;
- neutralize, grayscale, invert, rotate/remap, and median passes;
- worker-count tuning;
- perspective arithmetic and frame-padding fusion;
- PNG compression alternatives.

Important constraints:

- moving the ISO policy into the demosaic epilogue would cross LibRaw
  post-processing and change semantics; it is not an output-preserving fusion;
- `activeProcessorCount` includes efficiency cores and is not a P-core count;
  sweep worker counts rather than removing the cap on principle;
- the current working-tree perspective warp is already row-parallel;
- `Float` geometry or vImage can change interpolation and border rounding;
- changing internal RGB/BGR convention has a large blast radius for a measured
  roughly 0.05-second decode copy.

## Recommendation Disposition

| Original recommendation | Disposition |
|---|---|
| Port and tile RawTherapee X-Trans immediately | Replace with P0 LibRaw OpenMP determinism investigation |
| Run three X-Trans passes concurrently | Reject; later passes depend on earlier results |
| Parallelize RCD as P0 | Defer until Bayer fixture and timing exist |
| Treat unpack as an accepted floor | Reject; forced OpenMP accelerated the tested Fuji unpack |
| Optimize adjusted correction | Keep as P1; benchmark completed 2026-08-03, implementation next |
| Use vForce `pow` | Keep only as a measured candidate |
| Parallelize small full-frame passes | Keep as profile-gated cleanup |
| Lift worker cap to active processor count | Replace with per-kernel worker sweep |
| Port a parallel TIFF writer | Conditional on selected-compression usage |
| Prefetch the next full-resolution decode | Defer until stage costs and byte budgets are known |
| Optimize perspective warp | Low priority; current working tree is already row-parallel |
| Preserve atomic staging | Keep unchanged |

## Verification Matrix

Every performance change must state which cells it exercises:

| Concern | Required evidence |
|---|---|
| Latency | Release build, same input/settings/quality, warmup stated, at least 3 repetitions |
| Determinism | At least 5 identical repeats plus serial/reference comparison |
| Quality | Three-pass camera-scan contract; visual checks when numeric tolerance changes |
| Memory | Current and peak Mach physical footprint; allocator/RSS only as diagnostics |
| Formats | TIFF none/LZW, JPEG, PNG, and processed DNG as relevant |
| Adjustments | Neutral, tone, protected color, dye mixing, representative combination |
| Cameras | X-Trans now; Bayer only after a committed fixture exists |
| App behavior | Cancellation, collisions, cleanup, per-file errors, ordered batch |
| Distribution | Embedded dependency closure, notices, load paths, clean packaged launch |

## First Developer Handoff

A useful first pull request should contain instrumentation and tests, not the
final optimization. This handoff was completed across the 2026-07-28 through
2026-08-03 evidence slices:

1. add camera-scan repeat/determinism mode to `FilmScanExportBenchmark`;
2. expose hashes after unpack, inside the completed demosaic callback, after
   `dcraw_make_mem_image`, post-ISO, at the Swift image, and at packed-output
   boundaries;
3. add adjusted-correction benchmark scenarios and physical-footprint fields;
4. commit an X-Trans camera-scan fixture or document the local supplemental
   corpus command while licensing is resolved;
5. write the exact commands and results into
   `docs/performance/40mp-export.md`;
6. make no pixel algorithm change in that first PR.

The next pull request can enable the experimental threaded build and identify
the first divergent boundary. Only the following PR should fix or replace the
responsible implementation.

## Source Map

- `native/FilmScanEngine/Sources/CLibRawShim/RawTherapeePipeline.cpp`:
  camera-scan open/decode, X-Trans wavefront, parallel Fuji compressed unpack,
  RCD, ISO policy.
- `native/FilmScanEngine/Sources/CLibRawShim/CLibRawShim.c`:
  compatibility-profile mmap shim and profile dispatch.
- `native/FilmScanEngine/Sources/FilmScanEngine/RawImageDecoder.swift`:
  LibRaw-to-Swift copy/swizzle.
- `native/FilmScanEngine/Sources/FilmScanEngine/Processing.swift`:
  correction routing and calibrated-color seam.
- `native/FilmScanEngine/Sources/FilmScanEngine/FilmNegativeProcessing.swift`:
  fused power-law kernel and render-ready linear conversion.
- `native/FilmScanEngine/Sources/FilmScanEngine/RenderReadyLinearImage.swift`:
  serial linear tone/color/dye passes.
- `native/FilmScanEngine/Sources/FilmScanEngine/UInt16Image+Export.swift`:
  format packing, writers, staging, and atomic commit.
- `native/FilmScanEngine/Sources/FilmScanEngine/ExportFormat.swift`:
  TIFF compression default.
- `native/FilmScanEngine/Sources/FilmScanConverterMac/AppModel.swift`:
  sequential RAW batch orchestration.
- `native/FilmScanEngine/Sources/FilmScanEngine/ExportManager.swift`:
  decoded-image count heuristic.
- `native/FilmScanEngine/Tests/FilmScanEngineTests/RawImageDecoderTests.swift`:
  current RAW profile and quality coverage.
- `native/FilmScanEngine/Tests/FilmScanEngineTests/CameraScanByteIdentityTests.swift`:
  full-resolution camera-scan stage digests, wavefront-vs-serial X-Trans
  identity, and parallel-vs-serial Fuji unpack identity.
- `docs/performance/40mp-export.md`:
  authoritative committed benchmark procedure and results.

Upstream reference points:

- [LibRaw 0.21.4 X-Trans tiled OpenMP loop](https://github.com/LibRaw/LibRaw/blob/0.21.4/src/demosaic/xtrans_demosaic.cpp#L168-L180)
- [LibRaw 0.21.4 Apple OpenMP guard](https://github.com/LibRaw/LibRaw/blob/0.21.4/libraw/libraw_types.h#L48-L76)
- [RawTherapee X-Trans implementation](https://github.com/RawTherapee/RawTherapee/blob/dev/rtengine/xtrans_demosaic.cc#L181-L313)
- [RawTherapee tiled RCD implementation](https://github.com/RawTherapee/RawTherapee/blob/dev/rtengine/rcd_demosaic.cc#L80-L110)

## Non-Goals

- reducing final-quality X-Trans passes;
- speculative full-resolution RAW browsing or preview lookahead;
- changing pixel math merely to use Metal, Accelerate, or another library;
- reviving legacy Python performance work;
- promising hardware-independent speedup ratios from the isolated audit.
