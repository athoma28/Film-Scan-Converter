# Research registry and evidence workflow

Use this registry to find a research track, determine what its evidence supports,
and hand off the next bounded experiment. The [developer guide](../development/index.md)
owns build/test entry points; [development status](../development/native-macos.md#verification-summary)
owns completed verification of the native app; the
[roadmap](../improvements/MacOS-Native-Roadmap.md) owns product priorities.
This registry does not start a parked project or promote a fitted recipe.

## Tracks and maintained entry points

| Track | Status and scope | Start here | Evidence and limits |
|---|---|---|---|
| Paired Camera Raw color and controls | Active since September 18: diagnose photographic defects, fit public controls, review difficult frames, and preserve preferred looks | [Color evaluation runbook](../development/color-evaluation.md) | [September 25 follow-through](../development/roadmap-follow-through-2026-09-25.md#reproducible-color-workflow) records the schema-2 rerun. Per-frame fits and conditional skin transfers do not validate a complete stock profile on unseen photographs. |
| Photographic tone, grading and interaction | Implemented controls with maintained regression/diagnostic workflows; extend only for a concrete defect | [Tone contract](../development/photographic-tone-controls-2026-09-22.md), [slider response study](../development/slider-response-study-2026-09-24.md), and [separated tone ranges](../development/tone-range-separation-2026-09-24.md) | Use the later [verification summary](../development/native-macos.md#verification-summary) for same-source CPU/Metal and full-resolution output coverage. Dated findings refer to their recorded tone versions. |
| Performance and preview work | Active native product work, separate from color fitting | [Performance index](../performance/index.md) and [current architecture](../development/index.md#architecture-and-current-evidence) | Dated reports define source, workload, machine, repetitions and exclusions. Exact output checks and interaction measurements answer different questions. |
| Natural reference-curve fitting | Retained offline tooling and historical profile provenance; broader stock fitting remains parked | [Reference calibrator](../development/reference-negative-calibration.md) | Small-stock outputs can be explicitly unvalidated. Cross-validation also selects normalization strengths, so an independent final cohort is still needed for promotion. |
| Measured-density capture correction and broader stock calibration | Parked until the owner reactivates it; includes corpus preparation, new stock fits, curve digitization, LUTs, halation compensation and ML | [Processing reference](../film-processing-research.md), [experiment requirements](../research-brief-film-inversion.md), and [affine fitter](../development/density-matrix-calibration.md) | The committed fitter example is synthetic. No validated built-in capture correction is supplied by that fitter. |

## Color evidence map

The [October 3 upstream color audit](upstream-color-audit-2026-10-03.md) compares
NegPy's current data and processing with the native engine and checks
RawTherapee/LibRaw camera-color updates. It identifies bounded experiments;
it does not change defaults or establish new photographic improvements. The
subsequent [full X-T5 matrix study](xt5-matrix-study-2026-10-03.md) records the
fixed decoder-policy comparison, validation scope and photographic findings.
Its separate [reproduction record](xt5-matrix-reproduction.md) explains how to
rebuild the comparisons from the retained source/input bundle.

The three September 18 notes preserve the original scores, settings, failed
trials and user feedback. Later migration results belong in their own report;
do not rewrite historical numbers to imply that they were measured on the latest
engine. Private artifact paths below are repository-relative, ignored, and local
to the machine with the authorized corpus; they are not files shipped with the
documentation site.

| Checkpoint | Tracked account | Local artifact root | Interpretation |
|---|---|---|---|
| September 18 original paired study and follow-ups | [Paired controls](../development/camera-raw-color-study-2026-09-18.md), [Pro Image](../development/proimage-color-followup-2026-09-18.md), [segmented skin](../development/skin-rgb-study-2026-09-18.md) | `dist/camera-raw-study/` | Historical schema-1 corrections, 40 registered pairs, 12 selected skin presets. No guarded-run manifest; legacy app migration can change the scored result. |
| September 25 UTC interrupted migration run | [Follow-through](../development/roadmap-follow-through-2026-09-25.md#reproducible-color-workflow) | `dist/roadmap-color-2026-09-25/` | Manifest is interrupted after four completed stages. Preserve it as failure evidence; use the completed run for conclusions. |
| September 25 UTC completed public-recipe migration | [Follow-through](../development/roadmap-follow-through-2026-09-25.md#reproducible-color-workflow) and [verification summary](../development/native-macos.md#verification-summary) | `dist/roadmap-color-v2-2026-09-25/` | 29 completed stages, 40 registered pairs, two incomplete-pair exclusions, 254 exact app-applied recipe/pixel checks, 13 schema-2 named presets, five frozen preferences and 11 study JPEG exports. Five selected skin recipes have full-resolution checks; this is a subset of the 13 published candidates. |
| October 3 complete X-T5 upstream-color experiment | [Results](xt5-matrix-study-2026-10-03.md) and [reproduction](xt5-matrix-reproduction.md) | `dist/xt5-matrix-study-2026-10-03/` | All 40 pairs, three fixed recipes, both decode tiers, five historical preferences: 500 renders, 90 full JPEGs, 480 exact parser checks and 500 actual 900px GPU comparisons checked at the time. Candidate rejected: full color Clean Invert error +16.5%, all five preferred looks changed. Registration failures remain scored and reported; no decoder/default change. Compact reports/source inputs remain; galleries and exports are retired. |
| User appearance preferences | [Preference ledger](../development/color-preference-checkpoints.json) and [preservation procedure](../development/color-evaluation.md#fit-transfer-and-preserve-preferences) | Fresh runs write `preferences/` and `preference-checks.json`; original median metadata remains under `dist/camera-raw-study/` | Five snapshots cover Fuji DSCF3115 Automatic and both retained Phoenix DSCF3079/3086 variants. A lower Camera Raw error does not supersede the feedback. Historical medians are required for exact replay. |

The completed cumulative study's `color-study-run.json`, numbered stage logs,
`inventory.json`, `aligned-inventory.json`, `results.json`, `skin-color-results.json`,
`skin-review-results.json`, `control-probe.json`, and full-check reports form the
evidence chain. Completed galleries and generated pixels have been retired under
the [retention policy](../development/documentation-maintenance.md#keeping-evidence-available).
Regenerate temporary review images from the reproduction instructions when
needed. Neither a gallery nor a manifest alone proves image quality, output
integrity, or coverage of later source changes.

On October 2, 2026, this documentation pass inspected those local manifests and
artifact pointers and ran the read-only `doctor --workflow skin` and
`plan --workflow skin --full` entry points. Preflight found 40 complete triplets
and excluded Lucky DSCF5671/DSCF5676; dependencies were available. It did not
rerender the corpus, repeat the parser probe, refresh preference hashes, or run
new photographic/export/Metal validation. The
[verification summary](../development/native-macos.md#verification-summary)
remains the source for actual rendering checks.

## Define the next experiment before rendering

1. Record a visible problem, the intended decision and the narrowest useful cohort.
   Establish whether this is a per-frame correction, a transfer increment, a
   reusable profile, a processing-contract change or a performance experiment.
2. Read the maintained runbook and existing report. Record source revision plus
   relevant working-tree changes, exact settings/schema/tone version, input
   identifiers/content hashes, environment and decode/render tiers.
3. Declare fitting, candidate-selection and final evaluation data separately.
   Within-image withheld tiles are useful for overfitting checks but do not make
   photographs independent. Keep entire frames/rolls outside the full selection
   process before claiming reusable-profile validation.
4. Set the baseline, metric units, acceptance/regression limits and exclusions
   before inspecting the final evaluation scores. Include user-preferred looks,
   difficult individual regions and explicit non-skin colors where relevant.
5. Inspect preflight and the planned commands, choose a fresh output directory,
   and use the production engine. Keep source and input files unchanged during
   the run. A lower-level cached experiment needs its own explicit provenance.
6. Review registration, masks and images; retain unsuccessful trials and transfer
   failures. Validate published corrections through the real app parser, verify
   exact selected full-resolution settings for export claims, and measure Metal
   separately where it is part of the claim.

The [calibration proposal requirements](../research-brief-film-inversion.md)
add capture/setup and rollback requirements for the parked track when it resumes.
There is no need to rerun RAW galleries for a documentation-only change.

## Record and hand off the decision

Each dated result should include:

- The question, status, source/input/environment provenance and exact commands.
- Discovered, attempted, accepted and excluded cohorts with reasons; unrun checks.
- Baseline and selected recipe IDs/parameters, fitting versus evaluation metrics
  with units, region regressions, collateral changes and failed candidates.
- The decision, remaining uncertainty and a concrete next experiment or stop
  condition. Label whether the evidence supports a frame recipe, conditional
  transfer, whole-profile validation or only setup/contract checks.
- Tracked report/runbook links and local artifact paths. Identify dependencies
  needed to replay the result, including historical analysis metadata.

Update the relevant runbook when commands/contracts change, development status
when verification changes, and the roadmap when priorities change. Update this
registry when a track changes status or its evidence entry point changes. Keep
dated findings intact and add a short link to later evidence when needed.

For completed work, keep a results record and reproduction record plus a small
structured report/input bundle. The shared retained `dist/` budget is 250 MiB,
including releases and cleanup receipts. Keep stable preference and hand-authored region definitions tracked,
the original private corpus in `sample-raw/`, and required historical median/scan
inputs at the paths the harness reads. Temporary exports, numeric caches and
galleries belong in ignored fresh outputs and are removed after review. Per-run
parameter patches remain with the compact reports. Superseded committed snapshots
remain recoverable in Git history; ignored data does not. Do not replace checkpoint
hashes or historical medians to make a regression pass.
