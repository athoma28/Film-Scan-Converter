# Calibration Experiment Requirements

Calibration research is parked under the [roadmap](improvements/MacOS-Native-Roadmap.md#parked-stock-and-capture-look-calibration).
The [processing reference](film-processing-research.md) describes implemented
models and separates Natural curves, Darkroom unmix, manual crossover, and
measured-density capture correction.

If the owner resumes this work, an experiment proposal must state:

1. The visible photographic problem and why current controls are insufficient.
2. The exact input encoding, decode profile, geometry alignment, capture setup,
   and intended stage of the correction.
3. The licensed paired data, source-frame identifiers, stock/capture diversity,
   and frame-level fit/validation split.
4. The current-render and neutral baselines, acceptance metric, per-stock
   regression limits, and held-out visual review.
5. The deterministic CPU contract, preview/export and GPU tolerance boundaries,
   performance budget, persistence changes, and rollback path.

Use the existing [reference calibrator](development/reference-negative-calibration.md)
or [affine fitter](development/density-matrix-calibration.md) when its contract
matches the question. Report unsupported assumptions and failed validation.
Do not treat a small local collection, a named stock directory, or a fitted
candidate as permission to ship a stock characterization or start ML work.
