# Native performance implementation — October 2, 2026

Implemented the six ranked items from the
[discovery report](opportunities-2026-10-02.md), including shared RAW thumbnail
metadata. The rejected RGBA8 parallel-packing experiment remains excluded.
Existing processing defaults, user preferences, final quality, and unrelated
working-tree changes are preserved.

## Changes and contracts

1. **Exact density-print input lookup.**
   `DensityPrintProcessing` stores the original Double log-transmittance for all
   65,536 UInt16 input codes in a single immutable 512 KiB table. Scalar analysis,
   matrices, print response, and arithmetic order after lookup are unchanged.
   This optimizes CPU C-41/cyan rendering; it does not change Metal shaders.
2. **Thumbnail preparation on a worker.**
   `AppModel` prepares thumbnail CGImages on its existing utility worker, with a
   shared `CIContext` and explicit eager rendering. MainActor wraps the finished
   bitmap in an NSImage and publishes it. Cancellation checks are preserved.
   Tests cover worker isolation, named-sRGB complement, memoization, and
   independent concurrent outputs.
   The LibRaw thumbnail session now also returns optional authoritative source
   dimensions, avoiding a second RAW open in sidebar analysis. It preserves the
   existing legacy-geometry adjustment and orientation handling. Metadata failure
   leaves dimensions unknown and does not discard a valid thumbnail or substitute
   its small JPEG dimensions for source dimensions.
3. **Two-pass dust closing.**
   Default closing performs one combined-radius dilation and one erosion instead
   of five of each. The effective radius saturates safely at the image extent
   before multiplication. Neutral border behavior and the later component-mask
   dilation are unchanged. Component filtering reuses its completed BFS queue
   instead of duplicating those indices in another array.
4. **Resident stack reference.**
   `StoredScanStack` uses its already-retained first capture directly during
   merging. It spools only later captures, preserving capture indices, band
   boundaries, exposure weights, registration, and cleanup. Other captures still
   use the existing bounded storage and copies. At 7752 × 5184 RGB16, this removes
   241,118,208 requested write bytes and the same read bytes per stack—about
   460 MiB of logical I/O, not a measured physical-disk reduction.
5. **Bounded DNG packing.**
   The writer reuses a pixel-aligned buffer of at most 16 MiB while producing the
   same single-strip DNG byte stream. Header/tags, exact transfer lookup, staged
   commit, and total `packedPixelBytes` are preserved. Packing and writing stage
   timers account for their interleaved execution. Cancellation between bands
   and injected write failures preserve an existing destination and remove
   staging files. For 40 MP RGB16, logical packed storage falls from about
   230 MiB to 16 MiB.
6. **Skip invalidated preview stages.**
   Context-bound cancellation tokens stop remaining GPU detail or CPU packing
   work after source, geometry, or comparison changes. Active synchronous engine
   calls finish, and only one render worker drains at a time. Ordinary point
   edits keep useful intermediate publication. Final source/context checks still
   guard publication and retained corrected-raster caching.

The implementation does not retain CPU geometry across sessions, parallelize
initial photographic conversion, prefetch the next RAW export, or change
contact-sheet decode concurrency.

## Matched production measurements

Baseline engine objects and Swift modules were frozen before changes. Probes
link ordinary production release objects and retain executable, object, source,
input, and harness hashes. The candidate ran after the baseline, followed by a
frozen-baseline recheck. No concurrent native builds/tests ran during timing.
Background applications were not controlled; small cohorts and observed drift
limit generalization. Test-build timing is not performance evidence.

Hardware/software: Apple M4 Pro (Mac16,7), 14 CPU cores, 48 GiB RAM,
macOS 15.7.9, Swift 6.1.2, LibRaw 0.22.2. Base revision:
`2b4da0930df3ccebc08c1e3197a8ec242df448ac` plus the recorded pre-existing working
tree. About 31 GiB disk space was available before implementation.

### CPU correction and dust detection

The CPU point probe uses private `fuji400-fresh/DSCF2833.RAF`, a production
7752 × 5184 one-pass preview source, version-4 controls, and three timed exposure
values after warmup. It excludes decode, bitmap packing, export, and publication.

| Workload | Baseline median | Candidate median | Baseline recheck median |
|---|---:|---:|---:|
| C-41 complete CPU correction | 6.628 s | 6.049 s | 6.721 s |
| Cyan-mask complete CPU correction | 6.649 s | 6.138 s | 6.650 s |
| 2048 × 1365 dust, separated spots | 113.56 ms | 39.17 ms | 118.28 ms |
| 2048 × 1365 dust, clustered spots/scratches | 112.71 ms | 37.97 ms | 115.35 ms |

C-41 is about 9–10% lower and cyan about 8% lower in this bounded comparison.
All six complete-image sample hashes and 72 synthetic branch oracles match the
baseline and its recheck. This is CPU correction evidence, not a GPU or total
export speedup. A fresh-process first density-pixel call takes about 0.934 ms
with table initialization; warm calls retain exactly the baseline Double bits.

Dust probes each perform one warmup and three complete `findMask` timings on
deterministic synthetic scans with active morphology. Both mask hashes and
foreground counts remain unchanged: 6,909 and 107,722 pixels. Timing includes
gray conversion, thresholding, morphology, component filtering, and final mask
conversion; hashing is outside timing. These cases establish neither real-scan
detection quality nor dust-repair throughput.

The observed detector reduction is 65.5–67.1% against the two baseline arms.
Both dust changes are measured together; their individual contributions are not
isolated. All 24 masks, including warmups, match exactly.

### DNG and stack I/O

The DNG probe writes the same 7752 × 5184 deterministic UInt16 image in each
arm, hashing and deleting the output outside timing. Gray/RGB cases run in
separate processes. The stack case combines three identical 2048 × 1365 textured
captures in noise-reduction mode, including registration and temporary I/O.
Each case has one warmup and three timed observations.

| Workload | Baseline median | Candidate median | Baseline recheck median |
|---|---:|---:|---:|
| RGB16 DNG write | 146.34 ms | 103.21 ms | 101.29 ms |
| Gray DNG write | 16.32 ms | 13.89 ms | 24.82 ms |
| Three-capture stack | 3.455 s | 3.174 s | 3.246 s |

All **24 complete DNG files** and **12 stack pixel arrays**, including warmups,
match hashes across arms. DNG sizes and total packed-byte metrics also match.
Variation prevents a general throughput claim: the color candidate is slower
than the baseline recheck, and gray/stack samples have substantial outliers.

The first RGB write's physical-footprint high-water mark, sampled **before any
output hashing**, is about **463 MiB baseline versus 249 MiB candidate**. Gray
is about 156 versus 95 MiB. Later cumulative high-water marks include untimed
hashing allocations and must not be used as writer-memory measurements. Settled
candidate footprint is higher in this probe; this supports a transient writer
peak reduction, not sustained app-memory savings. Tests bound individual band
write sizes; the implementation allocates one reusable buffer of at most 16 MiB.

### RAW thumbnail metadata

Eight landscape X-T5 RAFs under `sample-raw/aesthetic-test/` were extracted at
256 × 171, each returning source dimensions 7752 × 5184. Input hashes, dimensions,
and all **72 recorded thumbnail hashes** match. Median of per-file medians is
26.57 / 26.43 / 28.61 ms for baseline/candidate/recheck. This does not establish
a general latency gain. The probe excludes app fingerprinting, bitmap inversion,
main-actor publication, and screen presentation. Rotated-source and metadata-error
behavior are not established by this eight-frame cohort.

## Verification and evidence

Fresh verification results are recorded in the
[development status](../development/native-macos.md#verification-summary).
The complete release suite passes **828 tests with 16 reported skips and zero
issues** in 473.691 s, including the opt-in six-frame photographic export test.
The production comparator passes all **4,608 cases**: 4,164 GPU comparisons
within 2/255 and 444 explicit CPU routes, with no render failures.

All six 7752 × 5184 TIFF exports reopen with exact production CPU pixels and
independently verified 16-bit named-sRGB metadata. Same-source app-preview and
CPU/Metal maximum differences are 1/255. One-pass interactive RAW and three-pass
export RAW differences are reported separately; the source tiers are not claimed
to be identical. Three fresh RAW decodes also reproduce all five preferred-look
PNG hashes and normalized settings exactly.

Focused/default tests cover exhaustive density lookup, independent repeated dust
morphology oracles, frozen dust fixtures, translated HDR/monochrome stack parity,
DNG exact bytes and cleanup, CPU/GPU render invalidation, point-edit publication,
off-main thumbnail preparation, and shared-context output agreement.

The initial focused run passed the production pixel and scheduling checks but
reported two new cleanup assertions comparing Foundation URL representations.
Those assertions now compare the complete enumerated filenames, including hidden
staging files, while retaining the exact existing-destination-byte checks. Both
pass in the complete suite. Production builds, C/C++ RAW compatibility, strict
Swift formatting, and whitespace checks pass.

All 244 final source/test/fixture hashes remain unchanged during final
verification. The final explicit eager-thumbnail setting was added after the
timed probes; engine sources used by those probes remain identical. Final
production app, renderer, and comparator binary hashes are also retained.

Ignored evidence is under `dist/performance-implementation-2026-10-02/`.
These paths are local artifacts; their
[availability limits](index.md#evidence-availability-and-provenance) apply in a
clean checkout or published docs site.

| Claim / provenance | Local record under that root |
|---|---|
| Frozen baseline, object/probe/source fingerprints | `baseline-manifest.json`, `baseline-*-link.json` |
| CPU correction, density initialization, dust masks and all three timing arms | `cpu-results.json`, `cpu-baseline.json`, `cpu-candidate.json`, `cpu-baseline-recheck.json`, `cpu-aux-*.json` |
| DNG bytes, first-write memory, stack pixels and variable timing | `io-results.json`, `io-*.json` |
| Eight-file thumbnail/dimension/input agreement | `metadata-inputs.json`, `metadata-baseline.json`, `metadata-candidate.json`, `metadata-baseline-recheck.json` |
| Suite/comparator/build results, photographic exports and preference checks | `verification.json`, `full-native-tests.log`, `production-comparator.log`, `production-build.log`, `photographic-export/`, `preferences/preference-verification-run.json` |
| Final source/test/fixture and binary stability | `final-source-manifest.json`, `final-binary-manifest.json` |

The
production renderer and tests, not external image math, produce the accepted
image outputs. Private images and generated artifacts remain ignored.

No native pointer replay, end-to-end screen-latency study, energy measurement,
physical-disk counter study, packaged distribution, or independent-Mac acceptance
was performed. Existing RAW quality and serialization contracts remain in force.
