# JPEG export correction — October 10, 2026

Current photographic JPEG export now runs its initial inversion and color-space
conversion through the same bounded CPU workers as its finishing stages. The
recorded C-41 correction median fell from 8.330 s to 3.474 s, with byte-identical
full-resolution JPEGs. Strong machine drift prevents a reliable general
end-to-end speedup multiplier.

## Change and quality boundary

`PhotographicProcessing.correctedPhotographicPreview` previously converted each
131,072-pixel-or-smaller scratch band to scene-linear values in a serial loop.
It now uses `processCorrectionPixels`, generalized to accept either Double or
UInt16 output storage. Independent pixels use disjoint output ranges with at
most eight workers, above the existing 100,000-pixel threshold. Band storage,
global analysis, per-pixel arithmetic order, presets and defaults are unchanged.
Small bands remain serial.

This reduces elapsed correction time before JPEG encoding and also applies to other exports
and CPU preview fallbacks that use photographic processing. It does not change
ImageIO, JPEG quality, subsampling, RGB8 packing, sRGB tagging, export dimensions,
staging/commit cleanup, or the final-quality three-pass RAW decode. It does not
replace that decode with a retained one-pass preview. Metal shaders are unchanged.

The existing benchmark's default workload uses historical legacy correction,
which bypasses the changed stage. A preliminary three-sample run of that mode
measured only about 0.15 s correction and 0.16 s JPEG encoding; it is excluded
from the current photographic comparison. `--film-base` now explicitly selects
a current neutral photographic workload and records its base and tone version
in the report. The historical default remains available. `--film-base` cannot
be combined with the fixed-workload `--determinism` or `--corrections` modes.

## Matched full-resolution measurement

The comparison used ordinary production release builds on Apple M4 Pro
(Mac16,7), 14 logical CPUs, 48 GiB RAM, macOS 15.7.9 (24G830), Swift 6.1.2 and
LibRaw 0.22.2. Base revision was
`2b4da0930df3ccebc08c1e3197a8ec242df448ac`, plus the recorded pre-existing
working-tree changes. An isolated baseline package retained the original two
engine source files. Both benchmark executables were copied and hashed before
timing; later builds could not replace them.

The sole input was private `fuji400-fresh/DSCF2833.RAF`, SHA-256
`c71a348038f397743360ca41a2ac099f51b81c1dd81e319b39e39a05711f2fe7`.
Each arm ran three complete sequential exports at **7752 × 5184**, using
`rawTherapeeCameraScan` full-resolution three-pass decoding, neutral tone
version 4, the `colorC41` film base, JPEG quality 0.95, and no frame. Run order
was baseline, candidate, then the frozen baseline again. No native builds or
tests ran during timing; other background applications were not controlled.

| Median stage | Baseline | Candidate | Baseline recheck |
|---|---:|---:|---:|
| RAW decode | 6.048 s | 8.845 s | 9.308 s |
| Photographic correction | 8.330 s | 3.474 s | 18.741 s |
| RGB8 packing | 0.014 s | 0.024 s | 0.040 s |
| JPEG encoding/finalization | 0.179 s | 0.202 s | 0.305 s |
| Complete measured engine path | 14.438 s | 12.945 s | 28.395 s |

Candidate correction is about **58% lower than the first baseline median** and
below both baseline arms. Unchanged decode, packing and encoding stages slowed
substantially across arms, and the baseline correction recheck more than
doubled. These observations establish a bounded improvement for the recorded
correction workload; they do not support a stable export multiplier, a broad
corpus estimate, or an app action-to-completion claim. The three samples per arm
do not estimate population tail latency. No warmup exports were discarded.

All **nine complete JPEG files** had the same 7,479,265-byte length and SHA-256:
`36c7e6ac5e024237988bc8edc83ef87bada70230c809e531cbb1560486e05984`.
Every file was hashed and deleted immediately by the benchmark. Process peak
physical footprint was approximately 701.6 / 701.8 / 701.8 MB in the three arms;
this run does not show a meaningful memory change.

Reproduce the candidate workload from the repository root with a fresh report:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/fsc-jpeg-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/fsc-jpeg-swift \
swift build --disable-sandbox -c release --package-path native/FilmScanEngine \
  --product FilmScanExportBenchmark

native/FilmScanEngine/.build/release/FilmScanExportBenchmark \
  sample-raw dist/jpeg-export-next.json 3 \
  --file=fuji400-fresh/DSCF2833.RAF --formats=jpeg --film-base=colorC41
```

## Verification and evidence

`PhotographicConversionTests` compares complete production UInt16 output with
serial tiles for seven inversion/positive branches across tone versions 2–4.
It crosses both the worker threshold and scratch-band boundary, including an
uneven final band, sensor-black pixels and channel extremes. The reference
tiles retain the same complete sensor as the global-analysis authority.

The final focused release suite reported **99 tests: 97 passed test functions
and two opt-in skips, with no failures**, in 12.235 s after compilation.
`ExportTests` passed all 30 functions. `PhotographicConversionTests` passed its
one function containing all 21 exact complete-output comparisons in 0.958 s.
Strict Swift formatting and whitespace checks passed for the changed files.

Separately, the current CPU/Metal comparator completed **1883/1883 cases**:
1439 GPU comparisons and 444 explicit CPU routes, with maximum channel error
1/255 and zero failures. This focused current suite checks synthetic parity;
it is not the full historical comparator cohort or a photographic Metal test.

The fresh preferred-look replay passed all five PNG-hash and normalized-setting
checks against the unchanged checkpoint ledger. It used three newly decoded
RAWs (Fuji DSCF3115 and Phoenix DSCF3079/DSCF3086), the newly built production
Swift Lookbook engine, and the exact archived historical medians. Source,
renderer and input hashes remained unchanged through the replay. Its preflight
found 40 complete triplets and excluded the two incomplete Lucky entries
`DSCF5671.xmp` and `DSCF5676.xmp`; only the three checkpoint RAWs were rendered
for this focused check. No fitting or reference-gallery run was performed.

The local evidence root is ignored `dist/jpeg-export-2026-10-10/`:

| Evidence | Local artifact |
|---|---|
| Source/input/environment and frozen executable hashes | `manifest.json` |
| Baseline/candidate/recheck samples and output hashes | `c41-baseline.json`, `c41-candidate.json`, `c41-baseline-recheck.json` |
| Compact comparison including memory and cleanup | `comparison.json` |
| Original changed engine files and exact task deltas | `Processing.swift.baseline`, `PhotographicProcessing.swift.baseline`, matching `.patch` files |
| Production build and per-arm console output | `*-build.log`, `c41-*.log` |
| Fresh preference replay, hashes and source/input provenance | `preferences/preference-verification-run.json`, `preferences/preference-checks.json`, `preferences.log` |
| Isolated baseline production sources, without build products | `baseline-sources.tar.gz` |

Generated JPEGs, preference PNGs, decoded study caches, copied executables and
the isolated build directory were removed after validation. Their hashes and
reports remain; the original archived preference inputs were preserved.

These private paths are not distributed with a clean checkout. See the
[performance evidence availability policy](index.md#evidence-availability-and-provenance).
This study does not establish photographic Metal parity, color-reference fitting,
full-corpus photographic quality, queue throughput, cancellation latency,
energy use or installed-app behavior.
