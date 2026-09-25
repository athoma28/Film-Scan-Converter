# Native diagnostic tools

## Agent entry point

Read the [color evaluation runbook](../../docs/development/color-evaluation.md)
before continuing color or film-preset work. It is the maintained guide for
setup, input naming, ordered stages, artifact formats, measurement rules,
preference checks, and adding photographs. Dated study notes below record results.

The current study uses Film Base / LookRecipe and schema-2 recipes. Its parser
probe requires exact applied settings and scored CPU pixels, while fresh frozen
preference renders preserve the historical looks. See the
[compatibility contract](../../docs/development/color-evaluation.md#current-compatibility)
and [current verification](../../docs/development/native-macos.md#verification-summary).
The September 18 galleries remain historical evidence.

```sh
.venv/bin/python native/diagnostics/color-study.py doctor --workflow skin --output dist/skin-study-next
.venv/bin/python native/diagnostics/color-study.py plan --workflow skin --full --output dist/skin-study-next
.venv/bin/python native/diagnostics/color-study.py run --workflow skin --full --output dist/skin-study-next
```

The runner pins a copy of the release renderer and records content hashes and
stage logs. It rejects source/input changes at completion as well as on resume.
`--resume` requires identical inputs, sources, tools and options. Use a fresh
directory for a changed experiment; legacy output directories cannot be adopted.
The Python dependencies are pinned in `requirements-color-study.txt`.

## Paired Camera Raw color study

The [September 18 color/control study](../../docs/development/camera-raw-color-study-2026-09-18.md)
recorded 40 paired RAF/XMP/JPEG references, fitted existing FSC controls, checked
cross-frame transfer, and exported schema-1 correction documents. Current Paste
Corrections migrates only public recipe fields; it is not proof of the historical
rendering, especially where source inversion or dye mixing differs.
`paired-reference-study.py` orchestrates production `FilmScanLookbook --paired-study`
renders; it does not alter app defaults or the user's presets. The note contains
the ordered reproduction commands and the limits of the measurements.

`proimage-color-study.py` fits public color controls for two Pro Image frames,
selects its starting recipe using training scores, writes `proimage-review.html`,
and checks all five saved preference snapshots. `skin-color-study.py` uses the
15 annotated frames, public-control/red-curve derivatives, explicit non-skin
patches, and training-only selection gates. Shared increments on held-out photos
remain conditional transfer experiments, not validated whole-stock profiles.
The historical [Pro Image](../../docs/development/proimage-color-followup-2026-09-18.md)
and [skin](../../docs/development/skin-rgb-study-2026-09-18.md) notes record earlier
methods, results, and failures.

`run-tonality-probe.py --paired-recipes dist/skin-study-next` compiles the actual
app clipboard parser with `PairedControlProbe.swift`, requires exact canonical
recipe reproduction, and checks destination calibration/framing preservation.
It never touches the real clipboard. A current release build is required.

Runner and recipe-contract checks need no RAW decoding or native compilation:

```sh
.venv/bin/python -m unittest discover -s native/diagnostics -p 'test_color*.py'
```

These cover discovery, content-hash provenance, pinned renderer integrity,
resume, native schema capture, preference decode defaults, public-control bounds,
and exclusion of held-out metrics from recipe selection.

## Ordinary slider response and native interaction

`run-tone-response-study.py` builds the production Swift engine and measures
ordinary small tone adjustments and combinations on six archived photographs.
It writes a gallery, fixed material/quintile masks, exact parameters, color and
texture metrics, CPU/Metal comparisons (`--metal`), and source/input/binary hashes.
All five preferred-look checkpoints are freshly rendered and must match their
recorded PNG hashes. Optional paired profiles compare exactly the same edits
across tone versions; `--correction-documents` exports native schema-2 recipes
without installing them. Its default study profiles use tone version 2; new app
edits now use version 4, while factory looks remain pinned to version 2.

`run-preview-interaction-study.py` builds and replays production ContentView in a
native window with the full Fuji DSCF2833 RAW, at Fit and 100%. It requires existing
Screen Recording permission and normal macOS graphics access. ScreenCaptureKit
samples only the diagnostic window; the output contains numeric revision-marker
observations and timing, with no captured screen images or audio. It separates
input scheduling, rendering, UI publication, and composited revision observations.
It does not measure native pointer dispatch or physical screen scan-out.

Use fresh ignored outputs, and do not change native sources or run concurrent
native builds/performance workloads. Both runners reject changed provenance.
Commands, baseline findings, candidate rationale and limitations are in the
[September 24 report](../../docs/development/slider-response-study-2026-09-24.md).
The ordinary test command skips the real-window benchmark. Diagnostic helper
tests can be run with:

```sh
.venv/bin/python -m unittest discover -s native/diagnostics -p 'test_*study.py'
```

## September 22 tone-control audit

`run-tone-control-audit.py` builds the production engine/renderer and measures
tone ramps, six archived 900px scans, and default cropped/uncropped rendering
latency. It requires the existing private study inputs and normal macOS graphics
access, writes only to a fresh `dist/` directory, and records source/input hashes.
`summarize-tone-control-audit.py` measures inspected content regions and plots the
recorded Swift outputs; it additionally requires Matplotlib. Commands, findings,
cohort and limitations are in the
[tone-control audit](../../docs/development/tone-controls-audit-2026-09-22.md).
This is diagnostic evidence, not a new tone contract or a default change.

Pass `--timing-only --output dist/c41-refinement-next` for the bounded one-RAW
performance cohort without ramps or disk images. It needs only
`sample-raw/fuji400-fresh/DSCF2833.RAF` and Metal access, records render-return
versus full bitmap-consumer time, and captures memory and repeated pixel hashes
in a separate untimed pass. See the
[Stage 2 collection report](../../docs/performance/c41-refinement-discovery-2026-09-22.md).
The photograph summarizer requires the full audit output and is not used in this mode.

## Tonality fixtures

`BWTonalityProbe.swift` exercises the production CPU inversion and merge code
with a 256 × 256 ramp and a few synthetic pixels. It does not decode RAW files,
run the app, or change profiles. Its output describes existing behavior;
it is not a regression test that endorses tonal collapse or clipping.

From the repository root, with a **current release build** already present:

```sh
python3 native/diagnostics/run-tonality-probe.py > /tmp/fsc-tonality.json
```

The runner compiles and links only the probe. It requires Swift, `pkg-config`,
LibRaw, and an existing release Lookbook, app, RAW benchmark, or test product link list.
It uses Swift's `-disable-access-control` frontend flag only when compiling this
probe to access the internal merge stage; production compilation is unchanged.
It never starts an implicit package rebuild. It
cannot certify that existing objects match the source: rerun the appropriate
release build after engine changes before interpreting the results.

If no current release build exists, the focused test command in the
[performance research note](../../docs/performance/research-directions-2026-09-12.md)
creates one. That compilation is substantially more expensive than this probe;
do it when power/compute are available.

The HDR fixture supplies perfect registration and exact exposure offsets to
isolate merge range handling. It does not test automatic registration or exposure
estimation. The low-code fixture isolates transfer-table quantization. Neither
fixture predicts the improvement in a real photograph.

See the [B&W tonality investigation](../../docs/performance/bw-tonality-2026-09-13.md)
for the results, caveats, and proposed experiments.

## Follow-up experiments

```sh
python3 native/diagnostics/run-tonality-probe.py --pass-two > /tmp/fsc-pass-two.json
```

This selects `ResearchPassTwoProbe.swift` and compiles the actual
`PerFileSettingsStore.swift` alongside it. The probe measures a few synthetic
settings saves in a temporary directory, compares an exact Natural B&W lookup
prototype with the current engine, and evaluates curve/transfer/merge-noise
fixtures. It does not read or write the user's real settings file. The 640-path
synthetic case corresponds to the history count observed during the investigation.

The [second-pass report](../../docs/performance/research-pass-two-2026-09-13.md)
separates measured results from implementation proposals. The prototype is not
used by the app and does not replace its profiles or merge algorithm.
