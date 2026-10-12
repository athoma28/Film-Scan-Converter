# Retaining CPU preparation across cached RAW revisits

Collected overnight October 10–11, 2026 on Apple M4 Pro, Mac16,7, 48 GiB RAM,
macOS 15.7.9, Apple Swift 6.1.2 and LibRaw 0.22.2. The [numeric report](cpu-revisit-preparation-2026-10-11.json)
contains every timed sample, work counter, memory snapshot, source/binary/input
fingerprint and derived range. Original full JSON and logs remain in the ignored
`dist/roadmap-loop-2026-10-10/` evidence folder.

Keeping CPU preparation with its decoded session removed a repeatable first-edit
cost after cached navigation in this two-RAW workload. Revisit publication medians
fell from 1219.4–1248.9 ms across the baseline runs to 988.3–1032.3 ms in the two
candidate runs. Warm control medians overlap. The candidate retained substantially
more process physical memory after the timed work, so this is a measured latency
tradeoff with a higher settled footprint.

## Matched workload and timing boundary

The selected frame is Fuji DSCF2833, with distinct DSCF2851 as the navigation
neighbour. Both are one-pass full-source RAW sessions retained at cache depth two
under the normal machine byte budget. Persisted C-41 version-4 settings include a
perspective crop and 2-degree straighten, which force the production CPU route.
Each process runs three matched exposure 0 to 0.25 edits with orders warm/revisit,
revisit/warm, warm/revisit. Revisit means A to cached B to cached A; A's corrected
raster is reused before the first point edit. Initial decoding and the first full
warp are warmed outside the timer, and returning exposure to zero is outside the
timed arm. There are no gestures or proxy renders in these timed edits.

Timers cover the setter through publication of the complete current AppModel
raster, the render worker, and publication through statistics settling. Bitmap
hashing and a fresh same-source production CPU oracle run after timing. The
underlying source is 7752 by 5184; corrected output is 6580 by 4476. Polling is
10 ms. These are model events, with no native-input or screen-presentation claim.
The existing `lastPreparationMs` field measures request preparation, not CPU
geometry construction; the warp belongs to worker render duration.

Five processes ran in order baseline 1, baseline 2, candidate 1, candidate 2,
then the copied original baseline binary. All 30 timed edits used identical
parameters, performed one correction and zero accepted full-source decodes, and
matched the same exact full-raster CPU oracle. Cached A returns performed zero
corrections and exactly one rendered-cache hit. RAW file hashes were unchanged.

## Descriptive timing results

| Process | Warm publication median, ms | Revisit publication median, ms | Median paired revisit minus warm, ms | Warm worker median, ms | Revisit worker median, ms |
|---|---:|---:|---:|---:|---:|
| Baseline 1 | 1009.7 | 1219.4 | 213.4 | 1001.6 | 1215.1 |
| Baseline 2 | 1019.3 | 1231.1 | 211.7 | 1011.6 | 1226.8 |
| Candidate 1 | 1028.1 | 1032.3 | -27.4 | 1017.6 | 1021.0 |
| Candidate 2 | 990.1 | 988.3 | -1.8 | 985.7 | 980.5 |
| Original baseline recheck | 1026.2 | 1248.9 | 223.4 | 1023.2 | 1236.3 |

The original binary recheck restored the same first-edit penalty after the two
candidate processes. Comparing extrema of the baseline and candidate run-median
ranges yields a descriptive revisit publication reduction of 187.0–260.6 ms
(15.3–20.9%) and worker reduction of 194.1–255.8 ms (16.0–20.7%). These are small
sample range comparisons, not confidence intervals or population-tail estimates.
The machine was not established quiescent: a subsequent read-only process check
at 07:11 UTC showed unrelated CPU workloads. Those workloads were left running;
serial study execution and baseline bracketing do not eliminate external-load
variability.
The small negative candidate paired differences reflect the sample variation;
they do not establish that the first edit is intrinsically faster than a warm
edit. Full-source correction still takes about one second in this workload.

## Memory cost and ownership boundary

| Stage/quantity | Baseline range | Candidate range |
|---|---:|---:|
| Charged preview bytes before the oracle, MiB | 942.0 | 1110.5 |
| Physical footprint before the oracle, MiB | 98.8–104.4 | 441.3–451.4 |
| Physical footprint after verified model release, MiB | 70.6–76.2 | 75.9–86.2 |
| Process-lifetime peak physical footprint, MiB | 805.2–809.7 | 808.4–818.9 |

Charged preview accounting increased by exactly 176,712,480 bytes (168.526 MiB)
after all timed work settled. Physical footprint increased by approximately
336.9–352.7 MiB when comparing the before-oracle ranges. That larger physical
increase is an observed tradeoff; these samples do not isolate allocator/page
lifetimes or every retained owner well enough to explain it as one geometry
buffer. Charged bytes, physical footprint, reusable pages and process-lifetime
peak are separate measurements. The peak includes untimed decode, hashing and
oracle work. They do not show lower memory use or general capacity improvement.

The Close All sample still includes local source references retained by the
measurement's same-source correctness guards. The verified-model-release sample
is taken after that helper returns and its guard references leave scope. Reusable
allocator pages can remain after release. This two-session workload fits the
normal budget and does not demonstrate a long-roll capacity limit, system-wide
pressure response, or energy benefit.

## Production ownership and correctness gates

CachedPreviewSession now owns the full-source and continuous-edit CPU preparation
alongside the decoded sources and renderers. Applying a cached session restores
those owners; point edits retain compatible geometry. Geometry changes rebuild
within the same immutable-source owner. Session physical and reserved accounting
include mutable preparation bytes, while selected aliases are not charged twice.
Every completed worker trims the retained cache before cancellation/publication
checks and suspended completion hooks, so a stale worker's new geometry cannot
silently evade budget admission. Oversized selected sessions can still exceed the
budget; unselected owners are eligible for eviction.

Four deterministic app regressions passed: cached A to B to A owner and pixel
reuse for full and bounded edit sources; same-owner geometry invalidation;
pressure/Close All weak-owner and model release; and stale A geometry growth
trimmed while B is held before rendering completes. Session-cache regressions
also cover geometry accounting, admission, source replacement and shared owners.
The real-RAW exact oracle establishes this workload's CPU output correctness.
Photographic healing quality, export output, and Metal parity remain outside it.

## Frozen provenance and reproduction

The timed harness SHA256 is identical in both compiled cohorts:
`6ae6363158ebdd8de0795a55cdd757c9bd10e269670cf0237b3c88748c5ee651`.
The original compiled test bundle SHA256 is
`0ba223f537a0e9294ac4acbbd647ba3ed3db92496ca757db0772202e1a38906f`;
the candidate is
`35d258660f6f82a7301de4ef7c7626e1829f494bee4c51c02131c3c1e18ee3ed`.
Both were ordinary release builds of the dirty checkout at commit
`2b4da0930df3ccebc08c1e3197a8ec242df448ac`, with matching complete source manifests
and archives. Sources and test files outside this timed workload also differed;
the report identifies both complete cohorts rather than attributing every source
change to CPU preparation.

The harness's runtime executable hash identifies swiftpm-testing-helper. The
actual compiled test-bundle hash is external. The original-binary recheck ran
after candidate source changes, so its execution-time source hashes describe the
candidate checkout. The original workflow manifest/archive and copied original
bundle hash are authoritative for that recheck's compiled source identity.

For a fresh current-source run after coordinated build completion:

```sh
RUN_CACHED_REVISIT_EDIT_TESTS=1 \
CACHED_REVISIT_EDIT_OUTPUT="$PWD/dist/cached-revisit-next.json" \
swift test --skip-build --disable-sandbox -c release \
  --package-path native/FilmScanEngine --no-parallel \
  --filter CachedRevisitPointEditPerformanceTests
```

Use a fresh JSON/log path, normal graphics access, serial study execution, and
external pre/post test-bundle and complete source/archive fingerprints, and log
system-load conditions. Preserve
filesystem cache state rather than claiming a physically cold disk. Re-running a
copied original bundle requires swiftpm-testing-helper with explicit
`--testing-library swift-testing`, `--filter CachedRevisitPointEditPerformanceTests`
and `--no-parallel`; its `--help` argument is ignored.
