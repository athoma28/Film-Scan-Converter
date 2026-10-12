# Calibration Experiment Requirements

Broad stock/capture calibration research is parked under the [roadmap](improvements/MacOS-Native-Roadmap.md#parked-stock-and-capture-look-calibration).
The active September 18 paired color/control study follows its own
[evaluation runbook](development/color-evaluation.md); it does not reactivate
the broader fitting or ML project.
The [processing reference](film-processing-research.md) describes implemented
models and separates Natural curves, Darkroom unmix, manual crossover, and
measured-density capture correction.
The [research registry](research/index.md) locates maintained workflows and dated
evidence. Product priorities remain in the roadmap; these requirements define a
proposal for the parked calibration track when it resumes.

If the owner resumes this work, an experiment proposal must state:

1. The visible photographic problem and why current controls are insufficient.
2. The exact input encoding, decode profile, geometry alignment, capture setup,
   and intended stage of the correction.
3. The licensed paired data, source-frame identifiers/content hashes,
   stock/capture diversity, and frame/roll-level fitting, candidate-selection
   and final evaluation partitions. Keep final evaluation outside the complete
   tuning process, including normalization strengths, objective weights and
   model-family choices.
4. The current-render and neutral baselines, acceptance metric, per-stock
   regression limits, and held-out visual review.
5. The deterministic CPU contract, preview/export and GPU tolerance boundaries,
   performance budget, persistence changes, and rollback path.
6. The fresh output location, source revision and relevant working-tree changes,
   tool/environment versions, exact commands, failure/exclusion reporting,
   preference-preservation checks and tracked decision record.

Use the existing [reference calibrator](development/reference-negative-calibration.md)
or [affine fitter](development/density-matrix-calibration.md) when its contract
matches the question. Report unsupported assumptions and failed validation.
Do not treat a small local collection, a named stock directory, or a fitted
candidate as permission to ship a stock characterization or start ML work.
Use the registry's [record and handoff procedure](research/index.md#record-and-hand-off-the-decision)
for the result. A candidate that passes an offline metric gate still needs the
declared independent photographic, preference and production-output checks.
