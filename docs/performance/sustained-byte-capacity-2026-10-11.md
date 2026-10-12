# Eight-source CPU preview byte-capacity collection — October 11, 2026

One current-source release run warmed eight distinct Fuji X-T5 RAW files with
the default eight-session cache and normal 3 GiB preview budget. At warmup end,
only three full sources remained cached: five previously warmed full sources
had been evicted, while the app's memory-pressure drop-handler count was zero.
This establishes byte/reservation eviction below the source-count limit for
this workload. It does not establish an exact three-source capacity ceiling;
aggregate speculative admission reservations are not exposed.

All 32 measured selections immediately published a retained corrected canvas,
then accepted one full-source decode and one correction before settling. Median
model publication was 0.140 ms; median full-source, statistics, and background
settling was 2678.05 ms. This is a descriptive collection with no matched older
code control or capacity-improvement claim.

The [numeric report](sustained-byte-capacity-2026-10-11.json) preserves every
timing, work counter, dimension, cache state, phase footprint, input/hash
identity, and numerical processing setting. Common parameters plus one exposure
override reproduce all eight emitted final parameter documents exactly. Private
scans and complete logs remain in ignored local storage.

## Workload and publication boundaries

`SustainedPreviewPerformanceTests.sustainedNavigationAndPressure` used its
`fuji-eight-cpu` cohort: `fuji400-fresh/DSCF2833.RAF`, `DSCF2851.RAF`,
`DSCF2856.RAF`, `DSCF2865.RAF`, `DSCF2873.RAF`, `DSCF2881.RAF`, `DSCF2888.RAF`,
and `DSCF2892.RAF`. The eight input digests were distinct and unchanged after
the run. Every full decoded source measured 7752 × 5184 pixels.

The test persisted identical C-41 schema-4 parameters in isolated settings,
profile, and preference stores: initial exposure 0 EV, 2° straighten, and fixed
normalized perspective corners `(0.08, 0.10)`, `(0.93, 0.08)`, `(0.91, 0.92)`,
and `(0.10, 0.90)`. It explicitly required the production CPU geometry path.
Corrected full bitmaps and logical previews measured 6580 × 4476 pixels. The
cache depth was eight and the asserted budget was 3,221,225,472 bytes (3072 MiB).

Initial import and seven warmup selections preceded four navigation loops in
the same eight-file order. A first-frame exposure edit, Original comparison,
direct app-pressure simulation, three recovery selections, Close All, and
verified model deallocation followed. The complete opted-in test passed in
133.220 seconds. That duration includes correctness checks and teardown; it is
not a selection-latency sample.

The first timer starts immediately before programmatic selection and
`loadSelection()`. For these 32 navigation samples the retained canvas was
present when that call returned. Its bitmap measured 3290 × 2238 pixels while
its logical dimensions remained 6580 × 4476. This records synchronous model
publication, not native-input latency, a SwiftUI frame, screen presentation, or
full-resolution detail.

The second timer uses the same start and waits for current `.rawFull` output,
aligned statistics, and drained loading, rendering, background work, retained
snapshot work, and stack analysis. Polling occurs every 10 ms. All eight sources
were warmed before navigation, but filesystem cache state and unrelated machine
load were uncontrolled. Heavy study work was scheduled serially.

## Observed timing and work

| Navigation boundary, 32 samples | Minimum | Median | p95, nearest rank | Maximum |
| --- | ---: | ---: | ---: | ---: |
| Retained-canvas model publication | 0.122 ms | 0.140 ms | 0.151 ms | 0.156 ms |
| Full-source, statistics, and background settled | 2455.58 ms | 2678.05 ms | 3336.33 ms | 3398.39 ms |

The p95 selects rank `ceil(0.95 × 32)` from the ordered samples. It is a
descriptive tail for this small collection, not a population estimate.

Every measured target lacked a cached decoded source before selection. Each
settled navigation state held three full sources, either three or four total
sessions, and eight retained canvases. The fourth session, when present, was a
RAW detail source. The selected full source always remained cached and charged
preview bytes always remained within budget.

Navigation totals were 32 accepted full-source decodes, 32 corrections,
32 statistics computations, 32 submitted/displayed snapshots, zero rendered
raster cache hits, zero dropped snapshots, and 60 lookahead submissions. The
accepted-result counter applies after cancellation/generation guards and before
speculative admission. Lookahead counts scheduler submissions, including work
cancelled before native decoding. Neither counter establishes the number of
native decode starts, completions, cancellations, rejected results, or admission
skips. A retained-canvas publication is separate from a rendered-raster cache
hit.

Import-to-first-full-settle was 4296.63 ms and included three accepted
full-source results, three corrections, and three lookahead submissions. It
includes work for other files and is not an isolated single-file decode time.
Final cumulative counters were 45 accepted full-source results, 60 corrections,
60 statistics computations, 61 submitted/displayed snapshots, one rendered
cache hit, zero dropped snapshots, and 85 lookahead submissions. The one cache
hit occurred during recovery, outside the navigation timing interval.

## Byte eviction, physical footprint, and release

The first capacity evidence was the eight-frame warmup state: three full/total
sessions, seven retained canvases, and 1,864,749,216 charged bytes (1778.36 MiB).
DSCF2833, DSCF2851, DSCF2856, DSCF2865, and DSCF2873 had each received a settled
full-source warmup and no longer had a full source cached. The cache count was
below eight and pressure-handler count remained zero through warmup,
navigation, edits, and the immediately pre-simulation state.

The byte budget also reserves space when admitting speculative work. Those
aggregate reservations are not emitted, so settled charge need not reach
3072 MiB before eviction occurs. The observations establish that the default
count cannot retain all eight full sources for these CPU settings; they do not
identify an exact source-capacity ceiling or compare capacity with older code.

All values below are MiB (bytes divided by 1,048,576). Charged preview bytes are
app ownership accounting. Physical footprint, lifetime peak, and reusable bytes
are separate Mach `TASK_VM_INFO` fields.

| Boundary | Charged preview | Physical footprint | Lifetime physical peak | Reusable |
| --- | ---: | ---: | ---: | ---: |
| Before model creation | — | 7.17 | 7.17 | 0.50 |
| First full-source import settled | 1045.40 | 271.91 | 845.55 | 2067.72 |
| Eight-frame warmup settled | 1778.36 | 80.61 | 1172.77 | 3521.83 |
| Four-loop navigation settled | 1806.50 | 53.83 | 1172.77 | 3550.31 |
| Retained revisit after exposure edit | 1832.26 | 53.96 | 1172.77 | 3550.36 |
| Original comparison | 1832.26 | 53.96 | 1172.77 | 3550.36 |
| Before simulated app pressure | 1832.26 | 54.10 | 1172.77 | 3780.31 |
| Simulated app pressure settled | 527.13 | 53.83 | 1172.77 | 3780.31 |
| Pressure released and background settled | 1045.40 | 53.79 | 1172.77 | 3780.27 |
| Close All settled | 0 | 53.30 | 1172.77 | 3780.27 |
| Verified model release | — | 53.30 | 1172.77 | 3780.27 |

Navigation settled samples charged 1806.50–1832.26 MiB and reported physical
footprints of 52.49–53.90 MiB. These physical readings are unusually low relative
to the app's charge. The archived helper, successful Mach-call guard, literal
field selection, and raw/public data mapping were checked; the observations
are preserved without attributing their cause or treating charged, physical,
and reusable bytes as interchangeable. These are settled samples, not each
switch's peak. The 1172.77 MiB peak covers the process lifetime.

Pressure was a direct call to the app handler. Its sampled count changed from
zero to one; the subsequent false release call did not increment it. It removed
all unselected sessions and retained canvases, preserved the selected image
hash and logical dimensions, and reduced charge from 1832.26 to 527.13 MiB.
This does not validate OS pressure notifications or establish that the small
physical-footprint change was caused by that eviction.

Close All drained work and cleared the preview, all sessions, retained canvases,
and charged bytes. A weak reference verified AppModel deallocation before the
last memory sample. That sample retained 55,891,152 physical bytes (53.30 MiB)
and 3,963,895,808 reusable bytes (3780.27 MiB). The checks establish ownership
release, not complete physical return to the OS or the cause of residual memory.

## Correctness guards and provenance

The passing compiled harness checked every settled navigation bitmap against
that frame's pre-edit warmup hash, along with current photographic/geometry
settings, published parameters, full-source kind, selected-cache presence, and
logical dimensions. The exposure edit from 0 to 0.25 EV replaced retained
pixels with current publication and changed the bitmap. Original produced
different pixels, disabled on departure, and restored the edited corrected hash
on return. Pressure preserved selected pixels; all three recovery selections
restored expected settings and hashes.

The report's final DSCF2833 hash belongs to its edited 0.25 EV result; the other
seven final hashes use 0 EV. The first frame's pre-edit warmup hash was asserted
inside the harness but was not emitted. Publication verification checks the
reported data and source/binary cohort; it does not independently decode every
navigation image. These reuse guards do not establish photographic quality,
an independent CPU oracle, or CPU/Metal parity.

`workflow-guards-5-manifest.json` and `workflow-guards-5-source.tar.gz` identify
the dirty working-tree cohort. Independent verification matched all 376
archived/current source files and all four actual release binaries to that
manifest and both pre/post receipts. The loaded release test bundle SHA256 was
`acde8e65748083792b0d5ffdadfadcf0366eea8f919e2cd2e8e88622f7d20663`;
the source archive SHA256 was
`689cfb8dd68d1ee57f92ff9f2cf69f1e95506825d6bbe696b2fe93abf8cb56f3`.
The numeric report records exact manifest, archive, input, original-report,
log, binary, and relevant source hashes. This same frozen cohort passed the full
release suite with 937 reported tests, 22 intentional skips, and zero issues in
165.268 seconds; that suite duration is separate from this collection.

The machine was an Apple M4 Pro Mac16,7 with 48 GiB RAM and 14 processors,
macOS 15.7.9 (24G830), Swift 6.1.2, and LibRaw 0.22.2. Thermal state was nominal
at collection start; that does not establish an idle machine. The original
report/log and independent verification receipt remain under
`dist/roadmap-loop-2026-10-10/`.

## Reproduction

Follow the [collection runbook](../development/data-collection-optimization-target-discovery.md),
build release binaries, and capture their source/archive/binary cohort before
running with the eight named private RAW inputs and a fresh output path:

```sh
RUN_SUSTAINED_PREVIEW_TESTS=1 \
SUSTAINED_PREVIEW_COHORT=fuji-eight-cpu \
SUSTAINED_PREVIEW_LOOPS=4 \
SUSTAINED_PREVIEW_OUTPUT="$PWD/dist/sustained-byte-capacity-<fresh-name>.json" \
swift test --skip-build --disable-sandbox -c release \
  --package-path native/FilmScanEngine --no-parallel \
  --filter SustainedPreviewPerformanceTests
```

The harness requires a fresh output, verifies eight distinct inputs and the
normal 3 GiB budget, and supports two through eight loops. Retain the complete
log and pre/post source/binary receipts. Schedule heavy collections serially;
do not interpret this single cohort as a before/after performance result.
