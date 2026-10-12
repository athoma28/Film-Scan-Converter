# Native roadmap development loop, October 10–11, 2026

This records a three-hour development and validation session beginning October 10
at 23:17:48 PDT (October 11 at 06:17:48 UTC), on the existing dirty checkout at
`2b4da09`. The initial working-tree patch, status and native source snapshot are
retained under ignored `dist/roadmap-loop-2026-10-10/`. Unrelated changes were
preserved. Environment: Apple M4 Pro / Mac16,7, 48 GiB RAM, macOS 15.7.9
(24G830), Swift 6.1.2 and LibRaw 0.22.2.
The clock-time loop ended October 11 at 09:18:05 UTC after
three hours of development, validation and evidence review.

The remaining roadmap starts with photographic judgment, realistic roll work and
measured frequent-workflow problems. Distribution, Computer Use acceptance and
independent repeated-capture quality remain deferred at the owner's request.
This session uses automated app-model and file-based checks; it does not replace
those acceptance decisions. Color defaults, factory recipes and the preferred-look
ledger are preserved.

## Concrete workflow repairs

- Every per-file settings save now validates the current disk document. A document
  corrupted or replaced with an unsupported schema after startup cannot be
  overwritten by a later edit. A failed session read enables recovery merging for
  the rest of that session, preserving repaired outside entries across subsequent
  saves while giving session edits precedence.
- App image exports preserve a file created at their reserved destination after
  enqueue. The job fails, removes its stage and chooses another name on retry.
  Direct engine and diagnostic writers retain their explicit overwrite behavior.
- Automatic dust repair checks actual donor availability on a worker, including
  existing repair exclusions. It saves only applicable stamps and consumes their
  original connected mask components. Rejected adjacent candidates stay marked,
  including when a successful stamp's feather overlaps them. Source, mask,
  settings and editor changes invalidate pending work. Accepted stamps retain
  their chosen donor in the existing saved-stroke format, so removing rejected
  proposals cannot make those regions eligible donor texture on the next render.
  The complete marked mask also excludes automatic donors, including large
  components and spots beyond the proposal cap. Reproductions previously selected
  texture from those omitted defects; new production-engine tests keep them out
  of accepted donors while preserving their original pixels and mask marks.
- Direct Heal now checks the proposed stroke on a worker before saving or
  consuming its marked path. A corner stamp with too few boundary samples
  previously saved a no-op and cleared the mark; automatic and explicit stamps,
  plus partially renderable paths, now reject atomically. One-point automatic
  brush stamps freeze their donor outside the marked mask; multipoint automatic
  paths retain their existing per-dab donor policy. Current source, mask,
  parameters and request ownership guard publication and its separate undo step.
  Manual mask consumption now uses the renderer's strict positive footprint.
  A two-pixel brush previously erased boundary marks whose source pixels received
  no contribution. Coarse cells clear only when one dab covers all represented
  source pixels; finer masks, cancellation and excessive work preserve the
  original mask. The bounded-work regression first proves a stamp clears a mark,
  then requires an excessive repeated workload to return the entire original mask.
- Direct cancellation before a dust repair or detection task starts now clears
  its busy state without launching a worker. Cancellation of an obsolete task
  cannot clear the state of a newer task or replace a subsequently edited mask.
- Cached preview sessions now retain their full-source and interaction-source
  CPU preparation. Geometry survives a cached revisit and remains charged to
  the existing LRU budget. Every worker return trims newly grown preparation,
  including when its rendered frame is stale and discarded. GPU rendering releases
  incompatible geometry from both CPU owners on the worker; compatible geometry
  remains reusable, including after the flat-density reference bypass.
- Auto Frame captures the source generation and framing inputs. Threshold,
  geometry, history and source-upgrade changes invalidate pending results without
  overwriting newer edits. Ordinary tone edits survive valid detection.
  A successful detection or mask repair during a slider gesture gets a separate
  undo entry; later pointer samples continue from that state. Full clipboard paste
  also records its own action. Invalid/empty clipboard commands leave the gesture
  coalesced.
- Cancelling image export prevents decoding the next queued standard image after
  current native work drains. Cancellation status counts committed outputs,
  rather than attempted jobs; collision-safe retry preserves previous files.

The dust renderer's planning refactor matched the session's initial implementation
exactly in 288 cases covering 6,623,040 UInt16 components: zero differing cases or
components. The standalone oracle retains its copied sources, hashes, harness,
compiler information and report under `dust-oracle/`. This is engine equivalence,
not an assessment of restoration quality on photographic grain or texture.
The frozen-donor engine repeated that same oracle with zero differences under
`dust-oracle-final/`. After the targeted direct-Heal guard, another fresh oracle
again matched all 288 cases under `dust-oracle-direct-heal/`. Direct
cancelled-task tests also require both planners to
return no results while the persisted renderer remains pixel-identical.
An independent integer-algebra check matched source-center cell ownership in
14,432 width pairs, with 2,078,112 source-center assignments and zero mismatches.
It checks that finite index calculation, rather than Swift execution, renderer
output, asynchronous publication or photographic quality.

## Validation workloads

Opt-in gates were added to the [test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md): a repaired
RAW framing/persistence/reopened-TIFF contract and a sustained three-RAW
navigation/pressure workload. They use isolated stores and fresh report paths.
The RAW gate compares full-resolution writer input against an independently
decoded production CPU reference; the navigation gate records current and peak
physical footprint separately from charged cache bytes and checks repeated full
rasters, cache eviction, pressure recovery, Close All and model release.

The retention/cancellation cohort passed the complete release suite with **899
tests reported, 21 intentional opt-in skips and zero failures**, in 164.143 s.
The corrected repaired-RAW gate passed separately: two saved repairs, relaunch,
framing and a reopened **3760×5264, 16-bit sRGB TIFF** matching fresh production
CPU pixels exactly. Source bytes were unchanged. The initial gate run had two
harness assertions corrected: transient measured medians are intentionally absent
from persisted parameters, and `/var` versus `/private/var` output paths must be
compared after symlink resolution. Its full TIFF comparison already passed.
The later complete-mask/frozen-donor cohort passed **87 focused tests with no
skips or failures**, followed by a fresh repaired-RAW gate in **17.811 s** with
the automatic donor now present in persisted settings. The TIFF again matched
fresh full-resolution CPU pixels exactly. The next frozen cohort passed the
complete release suite: **925 tests reported, 21 intentional opt-in skips and
zero failures**, in **165.278 s**. All 375 source/test inputs still matched their
pre-build hashes after the run, and the compiled binaries were fingerprinted.
Strict Swift formatting also passed.

The later direct-Heal cohort initially reported 936 tests with one test-fixture
history failure: its Undo assertion assumed an empty history despite the fixture's
existing Film Base action. Capturing the actual starting history corrected it.
Subsequent 937-test runs exposed an unchanged numeric-field focus-loss timeout.
Two fully isolated original checks passed; a second attempted isolated check
overlapped a full-suite startup and is excluded from repeatability evidence.
The test now separates native typing/resignation events, verifies ownership of
the field editor and successful responder resignation, and retains every original
assertion and the three-second deadline. Three serial diagnostic checks passed
in 0.480–0.496 s with the host still inactive. Production numeric controls remain
unchanged. This supports a test-sequence investigation, without establishing
rapid-input product acceptance or proving inactive-window state caused the failure.
The final frozen cohort passed the complete release suite: **937 tests reported,
22 intentional opt-in skips and zero failures**, in **165.268 s**. All 376
source/test inputs and four compiled executable hashes matched around the run;
strict Swift formatting passed. The source freeze differs from the preceding
cohort only in that native-field test fixture.

The final shared-dab/footprint engine repeated all 288 equivalence cases with zero
differences under `dust-oracle-footprint-final/`. A compiled copied-production
Swift proof checks the five-mark cross and integer/noninteger coarse cells.
Its original synthetic assertion expected an exact donor value and trapped;
boundary matching instead produced 29,648 from a 30,000 donor. The corrected
proof requires exactly one changed source pixel and four untouched boundary
pixels, with those four marks preserved. Both harness versions and attempts are
retained. This is strict-footprint evidence, not a restoration-quality score.

The eight-loop three-RAW workload passed **24 measured switches** with exact
revisit pixels. Each selection immediately published a retained half-size canvas,
then performed one accepted full-source decode and one correction under the
two-session count limit. Simulated app pressure preserved the selected raster,
dropped unselected sessions and retained canvases, and recovered through three
more selections. Close All cleared cache charges and weak-reference model release
passed; residual physical footprint remained, so this is not evidence that every
physical page returned to the OS. The separate current release comparator passed
**4,608 cases: 4,164 GPU comparisons within 2/255 and 444 explicit CPU routes**.
The final frozen engine repeated all 4,608 comparator cases successfully and freshly
matched all five preferred-look PNGs and normalized parameter documents after
three RAW decodes. The ledger and color defaults were unchanged. Preflight still
reports 40 complete pairs and excludes the two incomplete Lucky pairs; these
five historical appearance checks are not a fresh full-gallery quality study.
Its fresh repaired-RAW gate also passed in **18.082 s**: two saved repairs,
relaunch, framing and an exact reopened 3760×5264, 16-bit sRGB TIFF against fresh
production CPU pixels. All final workload source and compiled-binary fingerprints
matched before and after collection.

The isolated 640-entry programmatic edit replay passed: 60 exposure setter events,
59 current rasters published during the gesture, persisted final exposure and
3.59 ms final interaction-to-model-publication latency. These setters and model
events do not measure guarded-save parse/encode time or screen presentation.

The initial unmodified cohort passed the complete release suite
with 874 tests reported, 18 intentional opt-in skips and zero failures. A first
sandboxed attempt could not initialize AppKit controls correctly; it was stopped
and rerun with normal macOS graphics access. A focused build overlapped an edit
and was stopped before tests; subsequent builds use a source freeze. Neither
interrupted attempt is presented as a product regression.

## Bounded performance result

The [CPU cached-revisit comparison](../performance/cpu-revisit-preparation-2026-10-11.md)
retains five process collections bracketing the preparation change, with 30 exact
full-resolution CPU outputs. First committed edits after a cached revisit had
187–261 ms lower model-publication medians (15.3–20.9%) in this two-RAW geometry
fallback workload. Charged retained bytes increased by 168.526 MiB, and sampled
settled physical footprint increased by roughly 337–353 MiB; the latter cause is
not isolated. Warm-edit medians overlapped. This is a latency/retention tradeoff
for this workload, not an app-wide speed or capacity gain.

The [sustained three-RAW report](../performance/sustained-preview-2026-10-11.md)
keeps the 24-switch collection and all state samples separately from that
comparison. It establishes count-limit lifecycle behavior and residual physical
footprint, without saturating the development machine's normal byte budget.

The fresh [Detailed cached-revisit comparison](../performance/detailed-cached-revisit-2026-10-11.md)
brackets the current cohort with two baseline collections. First gesture model
publication medians were **90.6 ms current versus 308.3–311.8 ms baseline**;
paired revisit-minus-warm penalties were 4.3 ms versus 219.7–223.4 ms. All 18
viewport and 18 full-refinement arms passed fresh exact CPU guards. Full refinement
remained about one second. Charged bytes rose by 168.526 MiB, and physical samples
before the untimed oracle rose by 338.8–354.6 MiB, with the cause unattributed.
These broader dirty cohorts include later workflow changes; this is not an
isolated causal experiment or native input, continuous-drag, screen-latency,
Metal or photographic-quality acceptance.

The [eight-RAW byte-capacity collection](../performance/sustained-byte-capacity-2026-10-11.md)
passed **32 measured switches** with the normal 3 GiB budget and depth eight.
After warming eight photographs, three full sessions remained and five previously
warmed sessions were absent while the pressure-drop handler count remained zero.
This establishes eviction below the count limit, without an exact three-frame capacity claim.
Every measured switch immediately published its retained half-size canvas; full
settlement had a 2678.0 ms median. Simulated pressure, recovery, zero-charge Close
All and weak-reference release passed. The unusually low sampled physical readings
remain in the report without a cause, OS-pressure or complete-page-release claim.

## Evidence retention and remaining acceptance

The initial dirty native snapshot and final 376-file source archive are retained,
with a snapshot-relative patch separating this session's native changes. Logs,
numeric reports, settings, hashes, scripts and five preferred-look PNG byte values
remain in ignored `dist/roadmap-loop-2026-10-10/`. Task artifacts occupy about
134 MiB after retiring temporary baseline build data and intermediate pixels;
unrelated pre-existing `dist/` artifacts were preserved. Retention receipts list
the removed files and their hashes. The retired isolated baseline binaries and
review pixels cannot be recovered from hashes: rerunning needs a fresh build or
render from the retained sources, private RAW inputs and recorded environment.
The retained `verify-closeout.py` checks 439 hash bindings across the final native
sources, compiled executables, reports, ledger and snapshot-relative patch inputs.
It rechecks evidence identity without rerunning tests or replacing photographic
acceptance; use a fresh `--receipt` path under the ignored task directory.

Further roadmap work still needs photographic dust judgment, native input and
screen acceptance, controlled pressure on other machines, and transfer of the
cached-revisit benefit to other photographs and interaction patterns. The measured
memory tradeoff remains material. No color-default change or distribution claim
follows from these checks.

A later read-only queued-export audit found no additional source/settings/output
count defect in the remaining queue boundaries. Queue paths and reserved export
options stay aligned; per-file corrections are read when each request prepares,
as required by the current contract. This review produced no extra benchmark or
acceptance claim.
