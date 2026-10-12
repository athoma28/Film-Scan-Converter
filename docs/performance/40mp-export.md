# 40 MP Native Export Benchmark

`FilmScanExportBenchmark` measures the production engine's full-resolution RAW
decode, correction, geometry, pixel packing, and writer path. It does not time
stored-settings resolution, classification, destination reservation, queueing,
or app-level error reporting. Use the app-path benchmarks below for those
operations. [Development status](../development/native-macos.md) owns current
verification; the dated measurements here describe their recorded source,
workload, and machine, not current app latency.

## Workloads and measurement rules

Camera-scan export uses the final-quality, three-pass X-Trans
`rawTherapeeCameraScan` profile. The [RAW compatibility benchmark](../development/native-raw-benchmark.md)
uses the separate `rawPyCompatibility` profile and PPG interpolation. Their
decode times and pixels do not share a performance gate. RAW browsing uses
bounded one-pass draft, inspect, and full-sensor previews; it is not a substitute
for the three-pass export source. See the [preview architecture](../development/realtime-preview-plan.md).
The selected file may retain its last three-pass decode for settings-only
re-export, but changing selection drops it. The engine benchmark decodes every
job and therefore does not measure that app-level reuse. Do not prefetch another
export-quality RAW or keep a roll-sized three-pass decode cache. Reducing the
three-pass demosaic to one pass changes the final-export quality contract.

Compare release builds on the same source, decode profile, stage set, writer
format/compression, settings, and hardware. Record the source revision and dirty
state, input and output hashes, worker counts, individual samples, failures,
skips, and current plus peak physical footprint. The first repetition is only
labelled `first-run`: input hashing or earlier work can warm filesystem pages.
The report gives the median and nearest-rank p95 for totals and stages. With
three repetitions, p95 is the slowest sample, not a population-tail estimate.

Each output is hashed in 1 MiB chunks, its byte count recorded, and the file
removed and checked absent before the next repetition. The scratch directory
is removed on success or failure. This also applies to `--all`, determinism,
and correction-scenario runs. Use Mach physical footprint after intermediate
release and the process peak as memory evidence; resident size and `ru_maxrss`
can include clean reusable allocator pages. A July 9 ten-RAF run held peak
physical footprint at 686.11 MB and ended at 42.78 MB after release, while
resident size rose with reusable pages. Those are dated diagnostic values, not
a current memory threshold.

App export cancellation is cooperative. Export preempts speculative preview
work; the active decoder checks safe boundaries, and synchronous ImageIO or
writer calls must return before cancellation can complete. The app must report
which jobs finished, skip unstarted jobs, and leave no incomplete output. Report
observed cancellation latency rather than claiming immediate interruption.

## Run the engine benchmark

From the repository root with the local, ignored `sample-raw/` corpus:

```sh
swift build -c release --package-path native/FilmScanEngine \
  --product FilmScanExportBenchmark

native/FilmScanEngine/.build/release/FilmScanExportBenchmark \
  sample-raw /tmp/film-scan-export.json 3 \
  --file=fuji400-fresh/DSCF2833.RAF
```

The default formats are TIFF, JPEG, PNG, and DNG. `--formats=tiff,png` selects
formats; `--file=STOCK/NAME.RAF` selects a source, with an unambiguous basename
also accepted. Without `--file`, the first root-relative RAF in lexical order
is used. `--all --limit=10 --formats=tiff` exercises sequential memory, while
`--frame-percent=N` exercises frame allocation and geometry separately. The
report records per-sample totals, decode substages, writer packing, output hash
and removal, Mach physical footprint checkpoints, and allocator statistics.

`--tiff-compression=none|lzw` selects TIFF compression. The ordinary benchmark
defaults to LZW, while the app defaults to None; use an explicit flag when
comparing app-default TIFF writing. `--film-base=colorC41` selects current
neutral photographic controls with tone version 4. The other accepted bases
are `colorCyanMask`, `blackAndWhite`, `slide`, and `original`. Without that flag,
the ordinary benchmark retains its historical legacy correction workload.
The report's configuration records both the workload and TIFF compression.

PNG writing preserves exact 16-bit RGB samples, no alpha, and named sRGB with
ICC data. ImageIO uses a fixed Average lossless byte filter. Its compressed
bytes and size may differ from earlier automatic-filter output; reopened pixels
remain the output-quality contract. Use the focused writer regression command
in the [test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md#native-regression) before interpreting
timings.
Paired-reference diagnostic PNGs retain adaptive encoding for historical
preference-byte compatibility; this does not select the app's export filter.

The [October 2 DNG implementation](implementation-2026-10-02.md#dng-and-stack-io)
packs/writes the unchanged single-strip stream in pixel-aligned bands of at most
16 MiB. Each synchronous write borrows the band's bytes inside the reusable
buffer's mutable borrow, which ends before the next refill. Its packing and
writing are interleaved; their stage metrics accumulate
packing time and the remaining writer time separately. `packedPixelBytes` is
the complete payload written, not maximum live buffer storage. The recorded
transient peak reduction and variable throughput have their own matched probe;
the older writer observations below are not a fresh DNG baseline.

To repeat the frozen camera-scan stage check, use at least five repetitions:

```sh
native/FilmScanEngine/.build/release/FilmScanExportBenchmark \
  sample-raw /tmp/film-scan-determinism.json 5 \
  --determinism --file=fuji400-fresh/DSCF2833.RAF
```

`--determinism` writes one LZW TIFF per repetition, checks all eight stage
digests, and prints each repetition's digests and memory readings before report
assembly. It rejects fewer than five repetitions and does not accept
`--formats`, `--film-base`, or any explicit `--tiff-compression` flag because
its writer contract is fixed LZW. `FSC_XTRANS_WORKERS=1` and `FSC_UNPACK_WORKERS=1` select the
respective serial oracles; compare each with production worker settings.

The correction matrix decodes once per repetition and applies neutral, tone,
protected-color, dye-mixing, and combined correction to the same authoritative
full-resolution source:

```sh
native/FilmScanEngine/.build/release/FilmScanExportBenchmark \
  sample-raw /tmp/film-scan-corrections.json 3 \
  --corrections --file=fuji400-fresh/DSCF2833.RAF
```

It verifies and removes one LZW TIFF per scenario and records correction,
writer, memory, and pixel hashes. This fixed-LZW mode rejects `--formats`,
`--film-base`, and any explicit `--tiff-compression` flag.

## Run the app-path benchmarks

The opt-in preview benchmark uses the real `AppModel`, production RAW source
tiers, corrected preview renderer, cache, and latest-selection drain. It
records publication latency, logical cache bytes, and physical footprint; it
does not measure native input-to-screen presentation. Configured cache depths
report initial lookahead population, not a fully populated roll or a settled
long-session capacity curve.

```sh
RUN_APP_PATH_PERFORMANCE_TESTS=1 \
APP_PATH_BENCHMARK_REPETITIONS=3 \
APP_PATH_BENCHMARK_OUTPUT=/tmp/film-scan-app-path.json \
CLANG_MODULE_CACHE_PATH=/tmp/film-scan-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/film-scan-swiftpm-cache \
swift test --disable-sandbox -c release \
  --package-path native/FilmScanEngine --no-parallel \
  --filter AppPathPerformanceTests
```

The export benchmark runs ten production app-path TIFF jobs, adding duplicate
source jobs if the local corpus has fewer than ten RAFs. It then requests
cancellation during the first decode of a second queue. The report covers queue
completion, progress/status, cleanup, and physical footprint after model
release. Completed outputs are deleted as the benchmark observes them.

```sh
RUN_APP_PATH_EXPORT_PERFORMANCE_TESTS=1 \
APP_PATH_EXPORT_BENCHMARK_OUTPUT=/tmp/film-scan-app-path-export.json \
CLANG_MODULE_CACHE_PATH=/tmp/film-scan-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/film-scan-swiftpm-cache \
swift test --disable-sandbox -c release \
  --package-path native/FilmScanEngine --no-parallel \
  --filter AppPathExportPerformanceTests
```

These tests include app settings, queue, destination, and cancellation work
that the engine executable excludes. Read their scope alongside production
signposts before attributing latency to a stage.

## Frozen camera-scan oracle

The committed `camera_scan_decode_reference.json` fixes the full-resolution
three-pass `fuji400-fresh/DSCF2833.RAF` decode at 5184 × 7752 × 3. It was
recorded July 28, 2026 on Mac16,7 with a release build and stock Homebrew
LibRaw 0.21.4. The raw mosaic was 7872 × 5196 with filter code 9 and 36 CFA
bytes. Five repetitions agreed at every boundary; a debug run reproduced the
decode-stage digests. The production parallel X-Trans and compressed-unpack
implementations later reproduced the same reference. The current X-T5 LibRaw
upgrade adapter preserves this established oracle; see [RAW decoder
compatibility](../development/raw-decode-compatibility.md).

| Boundary | Meaning | Recorded SHA-256 |
|---|---|---|
| `unpackedMosaic` | Sensor data and CFA metadata after unpack | `2afd88477279486c912bcd7c9d09d7889b92ff51f13eb8f7c9ef13bc39131897` |
| `demosaicedImage` | Image inside the demosaic callback | `70092621482abb3a337b8956dacb86813863ef5be61aa84a44df22756f49127b` |
| `processedImage` | `dcraw_make_mem_image` result before ISO policy | `60be4a2510729f1b1be9600f8af61db05750527855ce29bf3accb427cad3f3de` |
| `postISOImage` | Image after ISO-adaptive policy | `7f81faea53fa4858625efe64141adbb035eb268fd2c922b4fbe8d7f1e5835ced` |
| `swiftImage` | Swift-owned pixels after copy/swizzle | `91cfb89a62f1fc7296d3b17840ce806b1881501e7f825d061a25f72b3a22d730` |
| `correctedImage` | Neutral film correction | `eb43e243ef8bbc161743e1ad9be4d793a45a0407084925cb4dbfc7463b34bdc4` |
| `writerInputPixels` | Writer input; equal to corrected image with no frame | `eb43e243ef8bbc161743e1ad9be4d793a45a0407084925cb4dbfc7463b34bdc4` |
| `outputFile` | LZW TIFF, 174,847,758 bytes | `7be6f460d7d47e46a41f1196c88dc4bce00a22c14583c0f64e5fdd7f6311007a` |

The first five hashes are committed in
`native/FilmScanEngine/Tests/FilmScanEngineTests/Fixtures/camera_scan_decode_reference.json`
and checked by `CameraScanByteIdentityTests`. The fixture's schema and digest
format are checked even without the local RAW. Digests hash raw buffer bytes;
this is a same-machine byte-identity contract, not cross-platform output
identity. A diagnostic run fails when a required boundary is missing or
malformed. The first divergent boundary identifies where a decoder candidate
changed output. A new oracle requires a documented repeated run and an
intentional quality decision, never an untested fixture refresh.

The September 1 `correction_scenario_reference.json` additionally pins five
full-resolution corrected-image hashes after an intentional protected-color
strength change. Its schema test always runs; its pixel test requires the local
RAW. The fixture lives at
`native/FilmScanEngine/Tests/FilmScanEngineTests/Fixtures/correction_scenario_reference.json`.
Neutral, tone, protected color, dye mixing, and combined scenarios must each
repeat exactly. A later processing change must explain any hash change and
verify preview/export behavior before refreshing the fixture.

## Why the decoder is parallel this way

The July 30 isolated LibRaw `LIBRAW_FORCE_OPENMP` worker sweep held the unpacked
mosaic equal to stock in all 30 samples. At two and four threads, demosaiced
pixels were repeatable but already differed from stock; at eight or more,
demosaiced results varied across repetitions. The first divergence was
`demosaicedImage`, not Fuji compressed unpack. This failed both the exactness
and determinism gates, so forced OpenMP remains disabled. Its one-thread result
matched stock. The old apparent speedup is not a production speedup.

The production X-Trans path keeps LibRaw 0.21.4's integer arithmetic and serial
work inside each tile. Overlapping 512-pixel tiles step by 496 pixels, and a
tile can read the 16-pixel halo of its left, above, above-left, and above-right
neighbours. A `row+col` wavefront would race with above-right; independent
`2*row+col` diagonals preserve that dependency and run across at most eight
workers. Fuji compressed strips decode independently, while LibRaw datastream
seek/read access uses a lock. The current unpack worker cap and concurrent
decode policy are in [native contracts](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/README.md).
`FSC_XTRANS_WORKERS=1` and `FSC_UNPACK_WORKERS=1` remain serial pixel oracles.

The August 13 wavefront run repeated all eight stage/output digests across five
eight-worker decodes, matching the July 28 reference; a one-worker run matched
too. Its dated three-repetition warm demosaic median was 2.859 seconds, versus
12.72–12.77 seconds in the stock serial reference run. The August 14 unpack
change likewise matched across five eight-worker
runs and a one-worker oracle. The same-session three-repetition unpack probe on
`DSCF2833.RAF` reduced unpack median from 1.335 to 0.266 seconds while retaining
the exact TIFF hash. Those dated timings isolate the change; they do not state
current export latency or today's worker cap.

## Other retained design evidence

- **Cold decode target:** A July 6 decomposed `DSCF0669.RAF` run measured
  19.710 seconds in three-pass X-Trans demosaic out of 21.678 seconds of decode
  and 27.685 seconds total. This identified the stage for investigation; it is
  an early single-source result, not a current export baseline.
- **Correction memory and exact pixels:** The August 3 correction matrix found
  a 1.984 GB process peak in serial adjusted linear processing. The August 12
  in-place and parallel correction change reduced the recorded peak to 1.017
  GB and reproduced every then-current corrected-image digest. Neutral and
  fused-neutral paths stayed unchanged. Decode times differed between runs,
  so their correction timings are directional rather than a controlled total
  export speedup. The September 1 fixture refresh changed only protected-color
  and combined hashes for an intentional opponent-shift strength update.
- **Compact writer packing:** A 7752 × 5184 RGB16 TIFF or PNG intermediate
  needs 241,118,208 bytes instead of padded RGBA16's 321,490,944 bytes;
  JPEG's RGB8 intermediate needs 120,559,104 instead of padded RGBA8's
  160,745,472. The July 11 same-image before/after run preserved output
  bytes and SHA-256 for TIFF, JPEG, PNG, and DNG. Packing is a bounded memory
  improvement; three-pass decode remains the dominant cold-export stage.
- **App-level decode reuse:** The August 30 selected-file buffer lets a
  settings-only re-export skip three-pass decode. Selection change, reset, and
  teardown release it; another file's batch export does not replace it.
  Injected-decoder tests cover that ownership. Engine benchmark timings always
  include a fresh decode, so they cannot measure this app saving.
- **Bounded app-path evidence:** An August 12 ten-job TIFF run completed in
  50.066 seconds, removed all outputs, observed 75.79–80.48 MB physical
  footprint during progress, and returned to 62.13 MB after model release.
  Cancellation requested during the next queue's first decode reached a safe
  boundary after 4.744 seconds, left no output, and left nine jobs unstarted.
  These are dated observations on that source and machine, not a current
  latency or memory threshold.

Re-run the matching harness after changing its inputs, tiers, processing,
queue, writer, or buffer ownership. Keep raw samples and stage evidence in a
fresh ignored output location. Commit only the evidence needed to support a
live claim or regression contract. The [roadmap](../improvements/MacOS-Native-Roadmap.md)
owns any new performance scope.
