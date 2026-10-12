# First detailed CPU gesture after a cached RAW revisit — October 11, 2026

In this two-RAW workload, the first detailed exposure publication after a cached
revisit had a median of 90.6 ms in the current release cohort, compared with
308.3 and 311.8 ms in the baseline and its later recheck. Warm controls were
86.3–90.6 ms. The current result therefore supports transfer of the previously
measured full-edit preparation benefit to the first detailed CPU gesture. Full
refinement on gesture release still took about one second, and the current
settled physical footprint was substantially higher.

The [compact numeric report](detailed-cached-revisit-2026-10-11.json) preserves
all 18 timed viewport samples, 18 separate full refinements, nine cached returns,
18 fresh CPU oracle rows, trace events, counters, footprint samples, full
processing settings, and source/binary/input fingerprints. This is a bracketed,
descriptive comparison of complete dirty source cohorts with multiple workflow
changes, rather than an isolated single-change causal experiment.

## Workload and publication boundaries

`DetailedCachedRevisitPerformanceTests.matchedFirstDetailedGestures` selects
`fuji400-fresh/DSCF2833.RAF` as A and distinct `DSCF2851.RAF` as its navigation
neighbour B. Both full-source sessions remain cached at depth two under the
normal 3,221,225,472-byte budget. The test uses isolated settings, profiles and
preferences, explicitly persisting C-41 schema-4 settings at EV 0 with fixed
perspective corners and a 2-degree straighten. Those parameters require the
production CPU path. The actual decoded source is 7752 × 5184; the corrected
complete raster is 6580 × 4476.

The programmatic preview demand represents 100% detail with a 1200 × 800 visible
region at (512,384), backing scale two and magnification one. Quantization and
overscan produce the requested detail rectangle (448,320,1344,960), checked
inside the corrected geometry. The overview bitmap is 1024 × 697 and the detail
bitmap is 1344 × 960. The overview's full logical canvas size does not make it a
full-resolution bitmap.

Each process has three pairs ordered warm/revisit, revisit/warm, warm/revisit.
Before each arm, untimed viewport exposure edits 0.125 → 0 and complete release
refinement warm the same geometry, analysis and bounded overview. The revisit
arm then navigates A → B → A, reusing A's complete cached corrected raster, with
no intervening setter before the timed exposure target. Both arms time the same
single EV 0 → 0.25 value inside an Exposure editing gesture.

The first timer begins after `beginEditingGesture` and immediately before the
setter, stopping when AppModel publishes the matching detail rectangle and full
current parameters with rendering complete. A matching trace revision confirms
full-source input, no continuous-edit source proxy, and the `CPU viewport`
renderer. The harness also records model interaction time, render duration and
worker-finish minus worker-begin time. Requests can offer a bounded proxy
overview to the renderer; these unsupported geometry settings use the
full-source CPU viewport owner. This does not measure the Fit proxy path.

The second timer begins immediately before `endEditingGesture`, stopping at the
newer complete current raster publication with no detail. Statistics and
background/snapshot work settle afterward. Bounded bitmap hashing and all fresh
CPU oracles are outside both timers. Polling is 10 ms. These boundaries measure
programmatic model publication and worker duration; they do not measure native
input, continuous dragging, SwiftUI drawing, compositor presentation or screen
latency.

## Descriptive results

| Process | Warm detail publication median, ms | Revisit detail publication median, ms | Median paired revisit minus warm, ms | Warm worker median, ms | Revisit worker median, ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Baseline | 90.563 | 308.330 | 219.667 | 79.373 | 307.025 |
| Current | 86.277 | 90.580 | 4.303 | 80.439 | 81.434 |
| Baseline recheck | 90.566 | 311.822 | 223.429 | 80.836 | 307.221 |

The baseline recheck restored the first-revisit penalty after the current run.
The baseline/current revisit publication run-median comparison is
217.750–221.242 ms lower (70.6–71.0%) in current. Worker medians show the same
pattern: about 307 ms on baseline revisits and 81.4 ms in current, with warm
workers about 79–81 ms. These ranges compare three-sample run medians; they are
not confidence intervals, tail estimates, or an app-wide improvement percentage.

| Process | Warm release-to-full publication median, ms | Revisit release-to-full publication median, ms |
| --- | ---: | ---: |
| Baseline | 1024.705 | 1022.404 |
| Current | 1043.727 | 1023.903 |
| Baseline recheck | 1027.820 | 1014.286 |

Full-release refinement remains a separate approximately one-second cost.
Viewport and refinement each performed exactly one correction and zero accepted
full-source decode results in all 18 arms. All nine cached A returns performed
zero corrections and exactly one rendered-raster cache hit. Accepted decode
counters exclude obsolete/cancelled results and do not count every native
start, completion or cancellation. Statistics can finish across the two
publication boundaries; their actual counters are retained without treating
them as one computation at each boundary.

## Memory cost and ownership

All values below are MiB, using bytes divided by 1,048,576. Before-oracle values
are sampled after all timed arms and full refinements settle, before the six
fresh CPU comparisons in each process.

| Boundary or quantity | Baseline range | Current |
| --- | ---: | ---: |
| Charged preview bytes before oracles | 946.10 | 1114.62 |
| Physical footprint before oracles | 179.50–195.32 | 534.13 |
| Physical footprint after verified model release | 67.60–83.36 | 85.13 |
| Process-lifetime physical peak | 799.66–815.46 | 816.92 |

Current charged accounting is 176,712,480 bytes (168.526 MiB) higher, while the
before-oracle physical increase is 338.81–354.62 MiB. The larger physical delta
is observed, with its cause unattributed. These measurements do not identify a
single geometry buffer, allocator/page lifetime or other owner as its cause.
Charged accounting, physical footprint, reusable bytes and process-lifetime peak
are separate quantities. The peak includes untimed decode, warmup, hashing and
oracle work and is not a per-gesture peak.

Close All drained render, background, snapshot and stack work and cleared the
preview/detail, cached sessions, retained canvases and charged preview bytes.
Its sample still contains the test's source reference used by the same-source
pixel guards. The final sample follows the helper's return, guard scope exit,
and verified weak AppModel release. Physical footprint remains above the
pre-model sample; ownership release does not establish complete physical return
to the operating system. This two-session workload does not establish longer-roll
capacity, controlled OS-pressure response, lower memory use or energy benefit.

## Exactness and source-backed explanation

All 18 viewport/full results have identical target parameters and match fresh
same-source production CPU full, overview and detail hashes and dimensions.
Every oracle also requires exact UInt16 overview equality to a fresh full result
resized to 2048 then 1024, and exact detail equality to the requested crop of that
fresh full result. Oracles run after all timed arms. Decoded source pixel and RAW
file hashes remain unchanged; both cached full sessions remain present through
each arm. These are reuse/invalidation correctness guards, without photographic
quality, export or CPU/Metal parity claims.

The CPU viewport implementation is unchanged between the baseline and current
source snapshots. The detailed request uses the full-source preparation owner.
Baseline cached-session application does not restore CPU preparation and source
generation creates a fresh owner; current cached sessions retain and restore
that owner. The same geometry key is used for full warmup and the detailed
request. This source inspection supports prepared geometry reuse as the
explanation for the measured pattern. The real-RAW harness does not directly
count owner geometry builds, and later workflow guards also differ between the
compiled cohorts. Machine load and filesystem caches are uncontrolled; serial
execution and baseline bracketing do not eliminate unrelated variability.

## Frozen provenance and availability

The run order was baseline, current, baseline recheck, with one passing opted-in
test per process in 29.072, 28.206 and 29.179 seconds. Every pre/post collection
receipt verified complete source identity and actual compiled executables:
372 baseline package files including the only added harness, and 376 current
package files. All 371 original baseline package files were unchanged. The
current cohort's full release suite reported 937 tests, 22 intentional skips,
zero issues and 165.268 seconds; its four actual executables and complete source
manifest were verified.

The identical harness SHA256 is
`76979c555fc3a681918a552bcda9166453cf8358b2815405e15c02282577a41f`.
The newly compiled detailed baseline test executable is
`6c595c09eef53e41fced09ba7281d800962091b7e27b49f042928853cf13c497`;
current is
`acde8e65748083792b0d5ffdadfadcf0366eea8f919e2cd2e8e88622f7d20663`.
Both identify dirty snapshots at commit
`2b4da0930df3ccebc08c1e3197a8ec242df448ac`; the shared commit is not the source
cohort identity. Baseline runtime source hashes match its staged old source in
both runs. The harness runtime executable is swiftpm-testing-helper; external
bundle receipts provide the actual test executable identity.

The machine was Apple M4 Pro Mac16,7, 48 GiB RAM, macOS 15.7.9 (24G830), Swift
6.1.2 and LibRaw 0.22.2. Thermal state was nominal at the start of each process.
That does not establish quiescent machine conditions.

Raw JSON/logs, source archives/manifests, the exact added harness and verification
receipts remain under ignored `dist/roadmap-loop-2026-10-10/`; private inputs remain
under ignored `sample-raw/`. The compact report gives repository-relative artifact
names and SHA256s. The isolated baseline `.build` was retired after direct
independent verification and all pre/post receipts. Its removal receipt retains
the discarded-file hash/size inventory and confirms all staged source files are
retained. The compiled baseline binary is no longer present: a hash cannot
restore it. A fresh baseline collection requires rebuilding the retained exact
source plus identical new harness using the recorded environment. The older
copied baseline executable from the committed full-edit study does not contain
this new detailed harness.

## Reproduction

Build and capture source/archive/actual executable fingerprints first, then run
the frozen release binary with a fresh JSON and complete log path:

```sh
RUN_DETAILED_CACHED_REVISIT_TESTS=1 \
DETAILED_CACHED_REVISIT_SAMPLE_ROOT="$PWD/sample-raw" \
DETAILED_CACHED_REVISIT_OUTPUT="$PWD/dist/detailed-revisit-<fresh-name>.json" \
swift test --skip-build --disable-sandbox -c release \
  --package-path native/FilmScanEngine --no-parallel \
  --filter DetailedCachedRevisitPerformanceTests
```

Use the two exact named RAW inputs, serial study execution and external pre/post
source/binary receipts. Preserve filesystem-cache conditions instead of claiming
a physically cold disk. The harness rejects an existing output path. No further
collection was required to resolve the bounded transfer question in these samples.
