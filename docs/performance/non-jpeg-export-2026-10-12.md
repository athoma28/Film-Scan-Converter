# Non-JPEG export investigation — October 12, 2026

The final production candidate uses ImageIO's fixed Average PNG filter to avoid
its search among row predictors. TIFF remains unchanged, and the DNG pointer
packing trial was rejected and restored to the exact initial dirty source.
The final three-scan comparison reduced complete engine export medians by
**6.2–11.8%** and PNG writer medians by **20.9–27.1%**, with exact reopened
16-bit pixels. This is the accepted PNG-only source, with DNG restored.

PNG remains lossless 16-bit RGB with named sRGB and an embedded ICC profile.
The product predictor changes compression bytes and therefore file hashes;
exact decoded pixels, depth, profile, dimensions, and orientation are the
quality gates. The paired-reference diagnostic writer retains adaptive PNG
encoding for historical preference-byte compatibility.
The completed combined trial below is retained as retired-arm evidence and does
not establish the final PNG-only candidate's timing.

## Production change and filter selection

`UInt16Image+Export.swift` supplies `IMAGEIO_PNG_FILTER_AVG` under
`kCGImagePropertyPNGDictionary` when adding the image to the destination. Average
is a reversible byte predictor; it does not quantize the 16-bit samples or change
the RGB16 packing, color space, processing parameters, or source decode. Staged
writing, atomic commit, late-collision protection, failure cleanup, and the
existing cooperative cancellation boundary remain unchanged.

The initial one-source probe put the filter key at the top level of ImageIO's
options. It had no effect. Moving it into the PNG dictionary selected the filter
and produced different compression bytes. Those setup observations remain in
separate reports; the ineffective options are excluded from the selected trial.

Fixed None enlarged the initial source's file by approximately 9.5%. Average and
Paeth were then checked on the three photographs below, with complete reopened
pixel and metadata guards. Fixed Paeth was slower on Lucky, so Average was
selected from this three-scan exploratory cohort. This is recipe selection on
the measured cohort, not validation of a universal fastest PNG filter.

## Matched cohort and timing boundary

The baseline is revision `2b4da0930df3ccebc08c1e3197a8ec242df448ac` plus the
initial dirty working tree recorded in the private manifest. It includes earlier
native processing and export work. This comparison does not use clean HEAD or
the older pre-JPEG-optimization source as its baseline. The manifest retains
the complete dirty state, source fingerprints, original export sources,
ordinary production engine-object fingerprints, and executable hashes.

Environment: Apple M4 Pro (Mac16,7), 14 logical CPUs, 48 GiB RAM, macOS 15.7.9
(24G830), Swift 6.1.2, LibRaw 0.22.2. Inputs are three distinct private
7752 × 5184 X-Trans scans:

| Input under `sample-raw/` | SHA-256 |
|---|---|
| `fuji400-fresh/DSCF2833.RAF` | `c71a348038f397743360ca41a2ac099f51b81c1dd81e319b39e39a05711f2fe7` |
| `harmanphoenixii/DSCF3079.RAF` | `af070eeeb03761eecedfdd65a5822b45c6fffcb7088c45f8dafa058b7efe7c7a` |
| `luckyc200/DSCF3811.RAF` | `db910d9cf183fe8c64e495d933834a66732f9aa901be44c7f4dd557c2c810494` |

Every measured export uses full-resolution three-pass
`rawTherapeeCameraScan` decode, the same `colorC41` film base and neutral
photographic tone-version-4 controls, and no frame. Three photographs through
one applied profile do not constitute stock calibration or unseen-photo
validation.

Both arms use the same direct `swiftc -O -whole-module-optimization` harness,
linked against separately frozen ordinary production engine objects. The full
link commands and object/executable hashes are recorded in `manifest.json` and `final-manifest.json`.
Test-enabled engine objects are excluded from this timing comparison. No native
builds or tests run during measurement. Filesystem pages are warm; other
applications are uncontrolled. No cold-disk, thermal, or energy claim follows.

There are three paired rounds per PNG source, rotating source order. Each
candidate is immediately bracketed by baseline-before and baseline-after on the
same source, yielding six baseline and three candidate samples per photograph.
The paired reference is the arithmetic mean of those adjacent baselines. All
samples and drift are retained; no slow samples are excluded.

The engine total sums RAW decode, photographic processing, geometry, RGB16
packing, and encoding/finalization. Output hashing and deletion are outside the
timer. Process wall time additionally includes launch and those checks. App
settings resolution, queueing, action-to-completion latency, UI publication, and
screen presentation are outside the engine timer. Stage medians need not sum to
the median of complete exports, and three candidate samples do not establish
population tail latency.

## Final PNG-only comparison

The accepted arm was rebuilt after restoring DNG. The final collection contains
27 exports: six baseline and three final candidate observations per source.

| Source | Total median baseline → final | Lower total elapsed time | Writer median baseline → final | Lower writer elapsed time | Median paired total ratio |
|---|---|---|---|---|---|
| DSCF2833 | 9.415 → 8.306 s | 11.8% | 4.585 → 3.340 s | 27.1% | 0.8899 |
| DSCF3079 | 10.608 → 9.946 s | 6.2% | 6.082 → 4.812 s | 20.9% | 0.9228 |
| DSCF3811 | 11.655 → 10.502 s | 9.9% | 6.639 → 5.204 s | 21.6% | 0.9002 |

| Source | Baseline PNG bytes | Final PNG bytes | Size change |
|---|---:|---:|---:|
| DSCF2833 | 112,680,084 | 113,239,004 | +0.496% |
| DSCF3079 | 162,618,681 | 162,622,973 | +0.003% |
| DSCF3811 | 185,985,657 | 185,872,406 | -0.061% |

Every output has the same 7752 × 5184 dimensions. Complete final PNG hashes
match the corresponding effective Average-filter probe, whose every reopened
16-bit pixel matched the production image and whose depth/sRGB/ICC checks passed.
All 27 final outputs were hashed and deleted successfully; there were zero
measurement failures, and source/input/executable fingerprints stayed unchanged.
Baseline-after/before total ratios ranged from 0.9268 to 1.0229. Median paired
total ratios imply 7.7–11.0% lower elapsed time; the table separately reports
ratios of pooled medians. All samples are retained. A 0.35-second cleanup of
completed preference rasters occurred during the first final round; no native
builds/tests ran during collection, and other applications were uncontrolled.

Median process peak physical footprint was approximately 701.5–701.7 MB in
both arms; differences below 0.2 MB do not show a meaningful memory change.
Per-stage and after-release footprint samples remain in the final reports.
Separately, the final PNG-only executable freshly reproduced complete baseline
TIFF None/LZW and DNG file hashes and removed all three verification exports.

## Retired combined arm and rejected DNG trial

The first matched arm combined PNG Average with borrowed-pointer DNG packing.
`comparison.json` retains all 48 exports: 27 PNGs, 15 DNGs, and six TIFFs.
It records zero measurement failures and successful output deletion throughout.
Its PNG complete-export medians were 11.59–14.02% lower and PNG writer medians
20.79–26.90% lower across the three photographs. These figures describe the
retired combined executable; accepted final-arm figures are reported above.

The DNG trial borrowed immutable source and transfer-lookup buffers within
synchronous worker scopes, preserving the exact sRGB-to-linear lookup,
BGR-to-RGB order, little-endian output, existing worker thresholds, 16 MiB band
limit, and file header. Complete DNG file bytes remained identical to baseline.
Packing fell approximately 18–35%, saving only about 2–5 ms. Complete exports
were flat or 0.08–2.32% slower, with variable and generally slower write samples.
Fuji has three paired DNG rounds; Phoenix and Lucky each have one exploratory
pair. These observations provide no useful DNG export-speed gain.

The DNG candidate was rejected. `UInt16Image+DNG.swift` was restored byte for
byte to the initial dirty source, preserving its pre-existing bounded-buffer,
cleanup, collision, and cancellation work. The retired source and arm manifest
remain available for diagnosis. The new independent band-boundary test remains
useful coverage of the unchanged production writer.

TIFF writer behavior was unchanged. One paired Fuji observation per compression
recorded approximately 0.11 s for uncompressed writing and 1.86 s for LZW.
Complete TIFF hashes and lengths agreed. Variation in complete-export totals
is noise in unchanged code and is not a TIFF speedup claim. The existing
compression choice/default was not changed.

## Correctness and preference guards

The focused release run reported **53 test functions, zero failures**, with two
explicit opt-in skips: the six-frame photographic full-resolution suite and
the real-RAW dust-repair export suite. The completed cohort includes
`ExportTests`, `BoundedIOTests`, `IndependentViewerOutputTests`,
`ExportDestinationTests`, and `ContactSheetExportTests`; the raw-dust and
photographic suites remained disabled in that invocation.

The app export contract passes ImageIO and `/usr/bin/sips` inspection for named
sRGB/ICC, depth, baked orientation, and framed dimensions. PNG cases include
single pixels, single rows/columns, and every UInt16 code with distinct BGR
channels and low bits. Complete reopened pixels agree. DNG's independent
conversion oracle covers every UInt16 code, small/partial bands, and both RGB
and grayscale images. The added 257 × 513 case crosses the parallel threshold
with a 100,003-pixel band, uneven worker ranges, and a smaller scalar tail; it
checks complete strip bytes, byte metrics, and unchanged source pixels. Existing
forced failure, collision, destination-preservation, and cancellation cleanup
checks remain in the focused cohort.

The diagnostic PNG writer in `PairedReferenceStudy` retains ImageIO's adaptive
encoding. This preserves normal color-study preference checks and historical
diagnostic PNG bytes while the product/benchmark exporter uses Average. The
checkpoint ledger and normalized settings remain unchanged.

The fresh preference replay passed all five historical PNG hashes and normalized
settings, as well as exact baseline/final BGR16 bytes and independently decoded
PNG pixels. Each arm freshly decoded Fuji DSCF3115 and Phoenix DSCF3079/DSCF3086
with the archived historical medians. Source/input/renderer fingerprints were
unchanged through the replay, and the checkpoint ledger was not modified.
Preflight found 40 complete triplets and excluded incomplete Lucky
`DSCF5671.xmp` and `DSCF5676.xmp`; only the three checkpoint RAWs were rendered.
No fitting, registration, or reference-gallery evaluation was performed.
The diagnostic build and production app build passed. The paired-study writer
change was validated by this fresh replay after the focused export test run;
it did not change the engine source tested by that run.

## Commands and retained evidence

Build ordinary production code before freezing the timing executable:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/fsc-non-jpeg-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/fsc-non-jpeg-swift \
swift build --disable-sandbox -c release --package-path native/FilmScanEngine \
  --product FilmScanExportBenchmark
```

The public engine benchmark now exposes TIFF compression in ordinary format
mode and records it in configuration. Fixed-LZW determinism/correction modes
reject an explicit compression override:

```sh
native/FilmScanEngine/.build/release/FilmScanExportBenchmark \
  sample-raw /tmp/fsc-non-jpeg-next.json 3 \
  --file=fuji400-fresh/DSCF2833.RAF --formats=tiff,png,dng \
  --film-base=colorC41 --tiff-compression=lzw
```

Use `--formats=tiff --tiff-compression=none` for the uncompressed TIFF lane.
For a matched comparison, reconstruct the baseline from its recorded snapshot,
use the manifest's identical ordinary-object/direct-harness link commands, and
freeze both executables before timing. The retained `measure.py` and
`summarize.py` reproduce the retired combined-arm plan; they use fixed output
paths, so direct any replay into a fresh ignored directory. The final PNG-only
runner is `final-measure.py`; it uses `final-manifest.json`, the frozen
`baseline-options` and `candidate-png-only` executables, and writes
`final-matched/` plus `final-matched-runs.json`. Its reproduction entry point is
`python3 dist/non-jpeg-export-2026-10-12/final-measure.py` after preparing fresh
paths and matching the pinned inputs/binaries. Frozen executables are retired
after validation; use the recorded link commands and source snapshots to rebuild.

Run the focused output gates with normal macOS application access:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/film-scan-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/film-scan-swiftpm-cache \
swift test --disable-sandbox -c release --package-path native/FilmScanEngine \
  --jobs 2 --no-parallel \
  --filter 'ExportTests|BoundedIOTests|ExportDestinationTests|IndependentViewerOutputTests'
```

Use the configured environment in the [color evaluation runbook](../development/color-evaluation.md)
for the preference replay. The private script supplies the baseline/final
renderers, historical checkpoint medians/settings, and independent pixel checks:

```sh
PYTHONPATH="$PWD/native/diagnostics" \
  .venv/bin/python dist/non-jpeg-export-2026-10-12/check-preferences.py
```

That script also uses fixed fresh-output paths. Preserve its original evidence
and select new destinations for a rerun.

Private artifacts under ignored `dist/non-jpeg-export-2026-10-12/`:

| Artifact | Purpose |
|---|---|
| `manifest.json`, `baseline-sources.tar.gz`, `*.baseline` | Initial dirty-source, input, toolchain, link/object/executable provenance |
| `initial-fuji.json` | Initial per-format stage collection |
| `PNGFilterProbe.swift`, `filter-fuji.json` | Ineffective top-level-filter setup experiment |
| `PNGFilterNestedProbe.swift`, `filter-nested-fuji.json` | Effective nested-dictionary filter comparison |
| `PNGFinalistProbe.swift`, `filter-finalist-{phoenix,lucky}.json` | Three-source Average/Paeth selection and exact pixel/metadata guards |
| `measure.py`, `summarize.py`, `matched/`, `matched-runs.json`, `comparison.json` | Retired combined-arm plan, complete samples, hashes/bytes, stage/memory summaries and cleanup |
| `retired-combined-manifest.json`, `UInt16Image+DNG.swift.retired` | Rejected DNG arm provenance/source |
| `cli-checks.json`, `focused-tests.log`, `final-app-build.log` | CLI validation, completed focused test cohort and app build |
| `check-preferences.py` | Five-look BGR16/decoded-PNG/historical diagnostic hashes/settings/unchanged-ledger guard |
| `preference-checks.json`, `preferences-{baseline,candidate}/run.json`, `preferences.log`, `preference-cleanup.json` | Completed fresh replay, fingerprints, exact pixels/settings/historical hashes and generated-raster cleanup |
| `final-manifest.json`, `final-sources.tar.gz`, `final-measure.py`, `final-summarize.py`, `final-matched/`, `final-matched-runs.json`, `final-comparison.json` | Accepted PNG-only source, matched observations, fingerprints, stage/memory/size summaries and cleanup |
| `final-other-{none,lzw}.json` | Fresh final-source TIFF None/LZW and DNG complete-file hash checks |

These artifacts and private RAW inputs are local evidence, not files available
from a clean public checkout. Do not replace missing inputs with nearby frames
or overwrite dated outputs when reproducing this collection.

A broad native suite, the explicitly skipped photographic and RAW dust cohorts,
installed-app/package validation, photographic Metal parity, native interaction
and screen timing, broader camera/source/machine cohorts, and energy/thermal
measurements were not rerun. CPU output agreement and second-reader inspection
do not establish those separate contracts.
