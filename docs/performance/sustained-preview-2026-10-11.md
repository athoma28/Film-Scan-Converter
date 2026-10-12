# Sustained RAW navigation and retained-canvas collection — October 11, 2026

One current-source release run completed eight passes through three named Fuji
X-T5 RAW files with a two-source decoded-session cache. All 24 timed selections
immediately published a retained corrected canvas in the model. Each selection
then accepted one full-source decode and one correction before settling to its
full-source result. This is evidence that the retained canvas survives decoded
session eviction and remains correct through edits, Original, simulated app
pressure, and Close All. It is a single descriptive collection without an old
code control; it does not establish a performance or memory improvement.

The compact [numeric report](sustained-preview-2026-10-11.json) preserves every
switch timing, work counter, settled cache state, phase footprint, input/hash
identity, and full final processing settings. Private scans, images, and complete
logs remain in ignored local storage.

## Workload and timing boundaries

`SustainedPreviewPerformanceTests.sustainedNavigationAndPressure` uses
`fuji400-fresh/DSCF2833.RAF`, `DSCF2851.RAF`, and `DSCF2856.RAF`. Their source
hashes appear in the numeric report. The test creates isolated settings,
profiles, and preferences, explicitly persists C-41 Clean Invert and initial
exposures 0, 0.125, and 0.25 EV, then imports and primes all three frames before
starting the eight measured loops. The cache count is two; the normal machine
preview budget is 3,221,225,472 bytes (3072 MiB). This cohort exercises the source
count limit, rather than saturating that byte budget.

The first-publication timer starts immediately before programmatic selection and
`loadSelection()`. When the current retained canvas is already present at return,
the test records its publication immediately after validating current parameters
and full logical source dimensions. These sub-millisecond samples measure a
synchronous model-state change. They do not measure a native input event, a
SwiftUI frame, or screen presentation. The retained bitmap has half the width
and half the height of the complete corrected bitmap, according to the captured
source contract; its logical dimensions remain full size. It does not provide
full-resolution detail.

The second timer runs from the same selection start until the current `.rawFull`
result, rendering, statistics revision, speculative/background work, retained
snapshot work, and stack analysis have all settled. Its 10 ms polling and these
extra settling conditions are part of this workload. Filesystem cache state and
unrelated machine load are uncontrolled. A read-only check at 07:11 UTC found
other CPU workloads; they were left alone. Study builds and heavy benchmarks
were run serially.

## Observed model publication and full-source work

| Measured navigation boundary | Minimum | Median | Maximum |
| --- | ---: | ---: | ---: |
| Current retained-canvas model publication | 0.148 ms | 0.162 ms | 0.296 ms |
| Full-source, statistics, and background settled | 1262.24 ms | 1414.10 ms | 1526.64 ms |

All 24 measured targets lacked a cached source before selection. After each
settled selection the cache held two full RAW sessions and three retained
canvases. Navigation totals were 24 accepted full-source decodes, 24 corrections,
24 submitted/displayed snapshots, 24 statistics computations, zero rendered
raster cache hits, zero dropped snapshots, and no new lookahead submissions.
These accepted-result counters exclude native decoding that is cancelled or
whose result is discarded. The retained-canvas publication is not a zero-decode
cache hit.

The import-to-first-full-settle sample was 2896.75 ms and included two accepted
full-source decodes, three corrections, and one lookahead submission. That
boundary can include background work for another file; it is not an isolated
one-file decode time. The complete opted-in test reported one passing test in
54.853 seconds. Final counters across import, warmup, navigation, correctness
checks, and pressure recovery were 34 accepted full-source decodes and 45
corrections. Only the 24-switch navigation interval supports the table above.

## Charged bytes, physical footprint, and release

All values below are MiB (bytes divided by 1,048,576), not decimal MB. Charged
preview bytes are app accounting; physical footprint and reusable bytes come
from Mach `TASK_VM_INFO`. A process lifetime peak remains cumulative after the
work that caused it has finished.

| Boundary | Charged preview | Process physical footprint | Lifetime physical peak |
| --- | ---: | ---: | ---: |
| Before model creation | — | 7.06 | 7.06 |
| First full-source import settled | 952.40 | 595.55 | 939.67 |
| Three-frame warmup settled | 1489.03 | 1181.80 | 1181.80 |
| Eight-loop navigation settled | 1527.39 | 1068.14 | 1258.58 |
| Before simulated app pressure | 1527.39 | 1068.88 | 1258.58 |
| Simulated app pressure settled | 706.15 | 608.24 | 1258.58 |
| Pressure released and background settled | 952.40 | 535.30 | 1258.58 |
| Close All settled | 0 | 302.61 | 1258.58 |
| Verified model release | — | 302.61 | 1258.58 |

The 24 settled navigation samples charged exactly 1,601,587,200 bytes each
(1527.39 MiB), with physical samples between 1065.49 and 1220.36 MiB. These are
settled samples, not each switch's maximum.

Pressure is a direct call to the app's handler, not induced operating-system
pressure. It removed the unselected decoded session and all three retained
canvases, leaving one selected session and the same selected image hash and
logical dimensions. Charged bytes fell by 821.24 MiB, while physical footprint
fell by 460.64 MiB at this phase boundary. When pressure was released, lookahead
accepted one new decode; the subsequent three selections recovered the expected
settings and corrected hashes.

Close All drained render, snapshot, background, and stack work and cleared the
preview, all cached sessions, all retained canvases, and charged preview bytes.
A weak reference then verified that AppModel had deallocated before the last
footprint sample. The process still reported 317,313,080 physical bytes
(302.61 MiB), compared with 7,406,096 bytes (7.06 MiB) before model creation, and
2,410,971,136 reusable bytes (2299.28 MiB). This establishes model/cache ownership
release. It does not establish complete physical return or explain the cause of
the residual footprint.

## Correctness guards and provenance

Every settled measured navigation bitmap matched that frame's pre-edit warmup
hash. Each selection checked current photographic adjustments, density profile,
C-41 film base, published processing parameters, `.rawFull` source kind, and full
logical dimensions. The first-frame edit to 0.25 EV replaced retained pixels with
current publication and changed the bitmap hash. Original produced different
pixels, disabled Original on departure, and later restored the edited corrected
hash and exposure. Pressure preserved the selected bitmap and logical
dimensions; the recovery visits restored expected hashes and settings. All three
RAW file hashes remained unchanged after the run.

The emitted final hash for DSCF2833 is its post-navigation edited result. The
other two final hashes retain their initial settings. The harness checks the
separate original warmup hash during the 24 navigation samples but does not emit
that first frame's pre-edit hash. Hash equality here checks same-workload reuse
and invalidation; there is no fresh CPU oracle, photographic-quality evaluation,
or CPU/Metal parity claim.

The captured `retention-and-detection-manifest.json` and
`retention-and-detection-source.tar.gz` bind this dirty working-tree cohort to
release test bundle SHA256
`981f0436a6d288d2ea93c4e1998073351cab1dada076e458df2e340c5323eb0d`.
The numeric report contains their hashes, relevant compiled source hashes,
current harness/AppModel hashes from inside the run, input hashes, and original
report/log hashes. The archive matches the captured relevant source files. The
same-machine environment was Apple M4 Pro Mac16,7, 48 GiB RAM, macOS 15.7.9
(24G830), Swift 6.1.2, and LibRaw 0.22.2. Thermal state was nominal at start;
that alone does not establish an idle machine.

## Reproduction

Build and capture source/archive/binary provenance first, then use a fresh
output path with the frozen binary:

```sh
RUN_SUSTAINED_PREVIEW_TESTS=1 \
SUSTAINED_PREVIEW_LOOPS=8 \
SUSTAINED_PREVIEW_OUTPUT="$PWD/dist/sustained-preview-<fresh-name>.json" \
swift test --skip-build --disable-sandbox -c release \
  --package-path native/FilmScanEngine --no-parallel \
  --filter SustainedPreviewPerformanceTests
```

The harness supports two through eight loops and rejects an existing output
path. Use the real three named RAW inputs and keep heavy study work serial.
Retain the complete log and source/binary manifest with each new collection.
