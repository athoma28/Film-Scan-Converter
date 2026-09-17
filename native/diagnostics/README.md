# Small tonality probe

`BWTonalityProbe.swift` exercises the production CPU inversion and merge code
with a 256 × 256 ramp and a few synthetic pixels. It does not decode RAW files,
run the app, or change profiles. Its output describes existing behavior;
it is not a regression test that endorses tonal collapse or clipping.

From the repository root, with a **current release build** already present:

```sh
python3 native/diagnostics/run-tonality-probe.py > /tmp/fsc-tonality.json
```

The runner compiles and links only the probe. It requires Swift, `pkg-config`,
LibRaw, and an existing release app, RAW benchmark, or test product link list.
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
