# Maintaining documentation and research records

Start with the [developer guide](index.md), then use the source that owns the
question. Update that source when behavior or evidence changes; link to it from
other pages instead of copying a second status or task list.

| Information | Maintained source |
|---|---|
| Available tools and user workflow | [Features](../features.md) and [How to Use](../how-to-use.md) |
| Current implementation and completed verification | [Development status](native-macos.md) |
| Ordered remaining product work and acceptance conditions | [Roadmap](../improvements/MacOS-Native-Roadmap.md) |
| Processing, persistence, preview and export contracts | [Native package](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/README.md) and [preview architecture](realtime-preview-plan.md) |
| Build, test, diagnostic and release commands | [Building](building.md), [test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md), [diagnostic tools](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/diagnostics/README.md), and [release runbook](native-release.md) |
| Research status, boundaries and evidence map | [Research index](../research/index.md) |
| Performance results, rejected candidates and remaining experiments | [Performance index](../performance/index.md) |
| Color study procedure and user-preferred appearances | [Color evaluation](color-evaluation.md) and [checkpoint ledger](color-preference-checkpoints.json) |
| Published artifact behavior | [Release notes](https://github.com/athoma28/Film-Scan-Converter/blob/main/RELEASE_NOTES.md) and its versioned release page |

## Updating behavior and evidence

Describe whether a change is in current source, in a packaged local build, or
in a published release. A source review date is the date the implementation was
inspected; it does not turn an older test or benchmark into a fresh result.
Preserve dates and source state on recorded evidence, including later focused
checks that do not cover the complete suite.

For a behavior change, update its contract and user-facing guide, the applicable
test command, and development status. Remove completed work from the roadmap
and retain its evidence link. If a dated report's conclusion has been superseded,
add a short status note and successor link while preserving the original result.
Do not rewrite old measurements to describe today's engine.

For an experiment, record the question, cohort, selection process, exact
baseline/candidate, commands, source revision and working-tree changes, input
and binary hashes where available, environment, units, failures/exclusions,
and decision. Separate measured results from hypotheses and next experiments.
The research and performance indexes provide the entry points for these records.
An experiment suggestion is not a second product backlog or authorization to
change defaults.

Color work must follow the color evaluation runbook. Preserve preferred looks,
failed transfers and per-region checks. A parser check, synthetic parity test,
within-image fit, or lower reference error supports its stated scope only;
broader photographic quality and full-resolution export need their own evidence.

## Keeping evidence available

Completed studies retain two readable records: results and the decision, then
the exact reproduction procedure. Keep the measured scores, settings,
failures/exclusions, source/input hashes, environment and validation logs in a
small structured report bundle. Retain source snapshots when a commit alone
cannot reconstruct the working tree that produced the result, and only the
small historical inputs a maintained harness actually reads. Target at most
250 MiB for retained data under `dist/`, including release artifacts and cleanup
receipts, rather than a separate allowance for each study. The original authorized private RAWs,
reference JPEGs and XMPs in `sample-raw/` are a separate source corpus.

Large result/measurement JSON files can be retained losslessly as `.json.gz`.
Keep manifests, source snapshots and required metadata in the layout the harness
reads; restore a compressed report before using a tool that expects plain JSON.
The [local-data commands](building.md#local-generated-data) provide dry-run
retention and single-report restoration. Compression preserves report bytes;
it does not preserve deleted image caches or make an old output resumable.

Full-resolution exports, repeated decoded rasters, floating-point scoring
caches, galleries, contact sheets, unneeded binaries and build scratch are
temporary review products. Keep explicitly pinned X-T5 renderers and frozen
comparison objects that the retained reproduction/compatibility harness reads.
Remove temporary products after the results, reproduction inputs
and evidence have been checked. A new review regenerates them into a fresh
ignored output, which may temporarily exceed the retention target while work
is active. Keep a generated image only if it is an explicit small harness input
or a user preference whose visual baseline is needed; being linked from an old
gallery is not a retention requirement.

Use repository-relative literal code paths for private artifacts, identify
whether a path is retained or retired, and link to the maintained reproduction
procedure. Retired gallery paths document the historical run; they are no longer
review entry points. Public Markdown hyperlinks into private directories break
on the documentation site and in a clean checkout.
For links from `docs/` to source files, tests, or repository READMEs outside
`docs/`, use the repository's GitHub `blob/main` URL. Relative links outside
the docs directory resolve in a checkout but fail in the built site. The checker
also verifies those GitHub source paths against the current local tree.

Keep tracked reports while they support a current decision, reproducible
measurement, or compatibility contract. Before removing data, check its readers,
retain required historical median metadata and explicitly selected scan inputs,
and verify the compact bundle's hashes. A retained hash is evidence of what was
checked, not a backup of the deleted pixels. Reproduction requires the original
private corpus and recorded source/environment; running today's engine is new
evidence and does not reproduce historical pixels automatically. Git history can
recover a committed snapshot; it cannot recover ignored private artifacts or
uncommitted source changes. Do not describe deletion as an archive saved elsewhere
unless that archive actually exists.

## Checking documentation changes

From the repository root:

```sh
python3 tools/check-docs.py
git diff --check
```

The dependency-free checker validates local Markdown links, heading anchors,
same-repository `blob/main` and `tree/main` source targets, MkDocs navigation
targets, and reachability of every docs page from that navigation. It rejects
links into private output directories. The documentation CI job runs the same
check. It reads conventional inline links, reference definitions, ATX headings,
and the list-form navigation used here; it is not a complete Markdown/YAML parser.

The checker does not fetch external URLs, execute documented commands, validate
numeric research claims, or render the site. Inspect commands against their
entry-point source/help, check artifact manifests when available, and state
which checks ran. If MkDocs and Material are already available, also run:

```sh
mkdocs build --strict --site-dir /tmp/fsc-docs-site
```

Documentation-only changes do not require new RAW fixtures, full galleries,
performance measurements, or native test runs. Do not claim those checks passed
unless they were actually run on the stated source.
