# RAW Performance Contracts

Current performance work is governed by measured bottlenecks and the
[product roadmap](docs/improvements/MacOS-Native-Roadmap.md). The
[40 MP benchmark](docs/performance/40mp-export.md) retains the dated experiment
results and hashes needed to reproduce the camera-scan oracle. The
[analysis benchmark](docs/performance/preview-analysis.md) covers CPU diagnostics
and Darkroom. This page is not a queue of unfinished optimizations.

## Current Implementation

Camera-scan X-Trans preserves LibRaw 0.21.4 integer three-pass output, serial
work within each tile, and the true overlap dependence including the
above-right 16-pixel halo. Independent `2*row+col` wavefront diagonals run across
at most eight workers. Fuji compressed unpack uses independent strips and
serialized seek/read access through the LibRaw datastream lock seam.

`LIBRAW_FORCE_OPENMP` remains disabled: the recorded worker-count experiment
first diverged at overlapping-tile X-Trans demosaic, while unpack stayed exact.
That failed candidate is retained as necessary evidence for this restriction.
Reducing final-quality demosaic passes is not an optimization under this contract.

Adjusted correction runs in place and in parallel. Export packing is compact.
App export retains one selected-file three-pass decode for settings-only
re-export and drops it on selection change. The engine benchmark intentionally
continues to decode each job; do not attribute app-cache speedups to its timings.

## Requirements For Another Change

- Profile the real workload and identify its responsible stage.
- Record revision and dirty state, source hashes when needed, hardware,
  toolchain, quality profile, worker counts, and selected writer/compression.
- Compare identical inputs and stages in release mode with at least three
  repetitions; preserve raw samples, medians, p95 definition, and footprint.
- Threaded decoder changes need at least five repeats against every approved
  stage/output digest, including serial worker settings as an oracle.
- Keep one authoritative RAW decode in flight; test cancellation and cleanup.
  Remove benchmark outputs after each repetition. Assess physical footprint,
  not RSS alone, for retained-memory growth.
- Keep same-machine byte identity unless an explicit product decision replaces
  it with a documented and visually qualified tolerance.
- Treat writer changes as format/compression-specific. TIFF defaults to none;
  an LZW benchmark is not default TIFF latency. Bayer work requires a real-file
  fixture and decomposed evidence before changing RCD.

Do not reopen overlapping OpenMP tiles, replace the interpolator, prefetch the
next full-resolution RAW, or promote unmeasured library rewrites from old timing
estimates. Those changes require new evidence and an explicit scope.
