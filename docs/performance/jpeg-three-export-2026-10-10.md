# Three full-resolution RAW-to-JPEG exports — October 10, 2026

The final candidate changes X-Trans homogeneity-map construction in the production
camera-scan decoder. It preserves pixel arithmetic and uses existing scratch
storage. The earlier CPU preparation and fusion experiments were removed because
they did not improve the measured profile stage.

The final five-round comparison reduced complete measured export medians by
**32.4–34.3% on all three scans**, exceeding the 20% target. All 45 complete
JPEGs were byte-identical to their same-source baseline.

## Change and quality boundary

After all directional derivatives are complete, the decoder computes the same
minimum derivative, in the same direction order, multiplied by eight. It stores
that threshold in the dead Lab plane, then counts the same nine neighboring
comparisons using contiguous columns within each direction. The loop order
exposes independent comparisons to the compiler. Counts remain exact integers
from zero through nine; the final homogeneity sums, direction ties, averaging,
and overlapping-tile wavefront remain unchanged.

The threshold map needs four bytes per pixel within the existing six-byte Lab
storage. Fixed-size byte copies preserve object lifetimes and alias rules, so
the change adds no scratch allocation. The RawPy compatibility path retains its
original homogeneity loop. The accepted candidate also retains LibRaw's CIELab
implementation and the original final 5×5 selection sums.

The final change does not alter three-pass export demosaicing, image dimensions,
film bases, look recipes, tone versions, color defaults, RGB8 packing, JPEG
quality/subsampling, sRGB tagging, or staged writer cleanup. Complete JPEG hashes
provide the photographic output guard for this cohort.

## Matched measurement

The baseline is revision `2b4da0930df3ccebc08c1e3197a8ec242df448ac` plus the
recorded initial dirty working tree, including the earlier October 10 parallel
photographic conversion. It is not a clean-HEAD or pre-conversion baseline.
Both frozen executables come from ordinary production release builds; test-enabled
builds are excluded from the accepted comparison. Source, executable, input, and
configuration fingerprints are checked before and after collection.

Environment: Apple M4 Pro (Mac16,7), 14 logical CPUs, 48 GiB RAM, macOS 15.7.9
(24G830), Swift 6.1.2, LibRaw 0.22.2. The three private inputs are distinct
7752 × 5184 X-Trans scans:

| Input under `sample-raw/` | Input SHA-256 prefix |
|---|---|
| `fuji400-fresh/DSCF2833.RAF` | `c71a348038f39774` |
| `harmanphoenixii/DSCF3079.RAF` | `af070eeeb03761ee` |
| `luckyc200/DSCF3811.RAF` | `db910d9cf183fe8c` |

All three use the same applied `colorC41` neutral photographic profile, tone
version 4, full-resolution `rawTherapeeCameraScan` three-pass decode, JPEG quality
0.95, and no frame. This measures three photographs through a fixed profile;
it is not a stock calibration or a comparison among three different profiles.

Five rounds rotate source order. Each candidate export is immediately bracketed
by same-source baseline exports: baseline-before, candidate, baseline-after.
That yields ten baseline and five candidate samples per photograph. Each process
exports once; no warmup samples are discarded. Filesystem pages are warm from
earlier runs, and these are not cold-disk measurements. No builds or tests run
during collection; other background applications are not controlled.

The engine timer sums RAW decode, photographic processing, geometry, RGB8 packing,
and JPEG encoding/finalization. Hashing and deletion occur after timing. Separate
process wall time includes launch and those checks. App queueing, settings
capture, UI publication, and action-to-completion latency are outside this timer.

| Complete engine-path median | Baseline | Final candidate | Lower elapsed time |
|---|---:|---:|---:|
| DSCF2833 | 5.052 s | 3.318 s | 34.3% |
| DSCF3079 | 4.994 s | 3.298 s | 34.0% |
| DSCF3811 | 4.998 s | 3.378 s | 32.4% |

| Stage median | DSCF2833 baseline → candidate | DSCF3079 baseline → candidate | DSCF3811 baseline → candidate |
|---|---:|---:|---:|
| RAW decode | 3.556 → 1.800 s | 3.441 → 1.766 s | 3.407 → 1.842 s |
| Applied photographic profile | 1.368 → 1.402 s | 1.371 → 1.344 s | 1.406 → 1.390 s |
| RGB8 packing | 0.011 → 0.011 s | 0.011 → 0.011 s | 0.012 → 0.011 s |
| JPEG encoding/finalization | 0.122 → 0.121 s | 0.182 → 0.182 s | 0.171 → 0.169 s |

The decoder supplies the improvement; the restored Swift profile code contributes
no systematic gain. Geometry is below one microsecond for this no-frame workload.
Stage medians need not sum to the median of complete exports.

Median paired candidate/baseline ratios were **0.6554 / 0.6622 / 0.6709** in
Fuji/Phoenix/Lucky order. Both paired ratios and ratios of complete-export medians
passed the ≤0.8 gate for every photograph. Each paired reference is the arithmetic
mean of its immediately adjacent baseline exports. Baseline-after/before ratios
ranged from 0.8494 to 1.1484; retaining all samples and both acceptance statistics
accounts for that observed machine drift without discarding slow runs.

Separate process-wall medians also fell from 5.083 → 3.359 s, 5.026 → 3.335 s,
and 5.033 → 3.411 s. Median process peak physical footprint was 701.60 MB baseline
and 701.58 MB candidate; this does not show a meaningful memory change.
All source, input, configuration, and executable fingerprints remained unchanged.
Every output retained the exact same JPEG hash, length, 7752 × 5184 dimensions,
and decoder identity, and was removed successfully after hashing. All 45 exports
passed with no measurement failures. Full JPEG hashes and per-sample substages,
memory, drift, and cleanup checks remain in `final/`.

Five candidate observations per photograph do not establish population tail
latency or a general camera/corpus estimate.

## Rejected and retired trials

The first trial combined inlined CIELab, rolling 5×5 selection sums, and prepared
Swift density constants. JPEGs remained exact, but exploratory total medians
increased by 1.87%, 4.06%, and 6.85%. Its candidate was linked from a release test
build with `-enable-testing`, while the baseline was an ordinary release build.
That configuration mismatch excludes it from accepted matched-production timing
claims. The candidate was rejected and its code removed.

The second trial used the accepted homogeneity reordering alongside prepared
density constants and a fused Swift photographic pass. Its ordinary-production
five-round comparison preserved complete JPEGs and all five preferred looks,
but profile-stage medians increased by approximately 4.8–5.2% on all three scans.
Those CPU changes and their added tests were removed by restoring the exact
initial dirty Swift sources. Final acceptance uses a fresh C++-only build and
measurement; the retired combined-candidate results are separate evidence.

## Verification, reproduction, and retention

`native/test-raw-compatibility.sh` now includes the production homogeneity helper's
independent C++ oracle at `-O3`, alongside existing C/C++ RAW adapter checks.
Its synthetic maps cover four/eight directions, full/partial/empty-center tiles,
NaN/Inf comparisons, and scratch canaries. These checks establish exact comparison
counts and memory boundaries; they do not replace real RAW output checks.

After restoring the initial dirty Swift sources, the final C++-only production
build passed in 47.05 seconds. The focused release `CameraScanByteIdentityTests`
passed all five tests in 16.050 seconds, with every real-RAW case enabled and no
skips. They verify recorded full-resolution stage digests, the serial X-Trans
oracle, and independent Fuji unpack worker settings. C11/C++14 compatibility
checks and all 96 optimized homogeneity-oracle maps passed.

The freshly rebuilt current CPU/Metal comparator completed **1,883/1,883 cases**:
1,439 GPU comparisons and 444 explicit CPU routes, zero failures, maximum channel
error 1/255. All five preferred-look PNG hashes and normalized settings matched
the unchanged checkpoint ledger after three fresh RAW decodes using the recorded
historical medians. The preference preflight found 40 complete triplets and
excluded incomplete `luckyc200/DSCF5671.xmp` and `DSCF5676.xmp`; only the three
checkpoint RAWs were rendered for this focused replay. No presets were fitted.

Two setup failures were resolved before final validation. A sandbox-only graphics
run could not provide Metal; rerunning with normal macOS graphics access passed.
The first preference preflight used system Python and stopped on missing NumPy
before rendering; the runbook's `.venv/bin/python` completed the replay. The failed
attempts and successful reruns are recorded separately in the validation evidence.
The final passes do not imply that the blocked attempts performed their checks.

A complete native suite, native UI/input latency, installed-app/package validation,
energy study, broader camera cohort, and complete reference galleries were not
rerun. Synthetic CPU/Metal parity is separate from photographic Metal acceptance;
these fresh JPEG and preference checks establish their stated CPU/RAW cohorts.

Reproduce the focused correctness gates with the local reference RAW available
and normal macOS graphics access:

```sh
bash native/test-raw-compatibility.sh
swift test --disable-sandbox -c release --package-path native/FilmScanEngine \
  --no-parallel --filter CameraScanByteIdentityTests
swift run --disable-sandbox -c release --package-path native/FilmScanEngine \
  FilmScanPreviewComparator --suite=current
```

Use the [color evaluation runbook](../development/color-evaluation.md) and its
configured `.venv` for fresh preference replays. The retained private
`verify-preferences.py` records the focused three-frame/five-look invocation;
its original output was fresh at collection and must not be overwritten by a
new replay. Do correctness builds and renders before freezing timing binaries.

Build the current candidate with ordinary production settings:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/fsc-three-export-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/fsc-three-export-swift \
swift build --disable-sandbox -c release --package-path native/FilmScanEngine \
  --product FilmScanExportBenchmark
```

For a matched rerun, reconstruct the recorded baseline from its retained source
snapshot in an isolated package, build both arms with the same ordinary-release
settings, and freeze their executables before timing. With those executable
paths and the original three RAWs available, use a fresh output:

```sh
python3 dist/jpeg-three-export-2026-10-10/compare.py \
  --baseline /tmp/fsc-three-export-baseline \
  --candidate /tmp/fsc-three-export-candidate \
  --output dist/jpeg-three-export-next --rounds=5 --profile=colorC41
```

Ignored `dist/jpeg-three-export-2026-10-10/` retains the compact manifest,
baseline source snapshot, comparison runner, final samples/summary, rejected
trial summaries, validation logs, and cleanup receipt. Final validation is
recorded in `final-tests.log`, `final-shim-tests.log`, `production-build.log`,
`production-comparator.log`, and `preferences/preference-verification-run.json`.
The manifest contains complete input/source/executable hashes. The retained
`baseline-sources.tar.gz` preserves the exact initial dirty source;
`final-source-delta.tar.gz` and `source-deltas/` preserve the final implementation.
`trial-01/` and `trial-02/` keep the rejected/retired experiments separate.

Cleanup removed **681.0 MiB** of task-generated images,
RAW render buffers, bytecode, and executable copies, **812.7 MiB** of native
build cache, and **28.0 MiB** of task module cache: approximately
**1.49 GiB** in total. Task artifacts retain **6.31 MiB** of compact evidence.
The task size uses logical bytes; cache receipts report allocated bytes.
The guarded cleanup verified original inputs, archived/current sources, retained
artifact hashes, and idle readers before deletion. Exact inventories are in
`cleanup-receipt-20261011T055924297130Z.json.gz`, `cache-cleanup.json`, and
`dist/cleanup-receipts/20261011T055945429622Z.json`.

The original private RAWs, historical preference/replay inputs, unrelated app
bundle, and unrelated working-tree changes are preserved. The next native build
will recreate its cache.
These local artifacts are unavailable in a clean checkout; the
[evidence policy](index.md#evidence-availability-and-provenance) applies.
