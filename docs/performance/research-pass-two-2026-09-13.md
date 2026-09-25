# Second research pass: editing latency, B&W lookup, and HDR fidelity

**Historical research snapshot.** Findings and proposed changes below refer to
the recorded September 13 source. Later implementation is tracked in
[development status](../development/native-macos.md); this report is not a second
list of pending tasks or a benchmark of current presets.

September 13, 2026. This follows the
[performance investigation](research-directions-2026-09-12.md) and
[B&W tonality investigation](bw-tonality-2026-09-13.md).

The strongest new results are a measured settings-persistence stall at a
representative history size, an exact B&W lookup-table prototype, and a
counterexample showing that the current HDR weights can increase error even
without clipping or misalignment. Production rendering and defaults were not
changed in this pass.

## Evidence and compute scope

The [probe source](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/diagnostics/ResearchPassTwoProbe.swift) links
against the existing optimized engine and compiles the actual
`PerFileSettingsStore.swift` source alongside it. It uses synthetic images no
larger than 256 × 256, eight HDR pixels, and temporary synthetic settings files.
There is no RAW decode, application launch, GPU benchmark, photographic refit,
or full test suite. The final probe took **1.015 seconds**, excluding compilation
and linking. An earlier version took 0.673 seconds before adding the HDR-noise
fixture and 640-path settings case.

Environment: arm64 macOS 15.7.9 (24G830), Apple Swift 6.1.2, optimized release
engine from the current `4e962c1` working tree. The earlier AppModel repairs remain
uncommitted. These short timings are observations, not stable benchmark rankings
or measured energy savings. Persistence has three samples per size; LUT timings
have one sample per scenario. No extrapolated 40 MP speedup is claimed.

Reproduce from a current release build:

```sh
python3 native/diagnostics/run-tonality-probe.py --pass-two > /tmp/fsc-pass-two.json
```

The [recorded JSON](research-pass-two-probe-2026-09-13.json) contains every sample.
See the [diagnostic README](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/diagnostics/README.md) for build assumptions.

## 1. Persistence is a credible source of the sluggish editing

`AppModel.updateParameters` calls `saveParameters` before `renderAfterEditing`.
That synchronously encodes and atomically writes the entire per-file settings
dictionary on the main actor. The entry count includes saved files outside the
currently imported roll.

The configured local settings file contained **640 entries**, 583 marked edited,
and 1,941,005 bytes. Only aggregate counts/size were inspected; no settings were
changed. The performance probe uses invented paths and settings, including a
640-entry case corresponding to that observed count.

| Synthetic saved paths | Production save, three samples | Written size |
|---:|---:|---:|
| 1 | 1.47 / 1.04 / 1.08 ms | 3,031 bytes |
| 100 | 6.91 / 6.85 / 6.56 ms | 295,936 bytes |
| 640 | **39.36 / 39.70 / 39.08 ms** | 1,894,768 bytes |
| 1,000 | 61.71 / 60.92 / 60.78 ms | 2,960,656 bytes |

The benchmark measures the real synchronous store operation; it does not measure
a live slider or prove its exact delay with the owner's complete settings.
Nevertheless, source order puts this cost before render submission. About 39 ms
already exceeds two 60 Hz frame intervals, independently of decode or GPU speed.

At 640 entries, pretty/sorted JSON encoding alone took 36.99–37.47 ms. Compact
sorted JSON reduced this only to 34.17–34.75 ms, despite reducing bytes by about
42%. Moving only `Data.write` off the main actor would leave most of the observed
cost. Removing pretty-printing is insufficient.

Implementation direction:

- Keep in-memory settings immediate, but send **per-file deltas** to a serial
  persistence owner that maintains its own dictionary. Encode and write there.
  Passing a new full dictionary snapshot each slider tick can also create
  copy-on-write costs when the next edit mutates it.
- Bound pending work to the newest value per key, with ordered revisions and
  explicit handling of remove/reset operations. Do not enqueue one full encode
  for every input event.
- Use the existing slider gesture boundary (`AdjustmentSlider.onEditingChanged`)
  for a final flush, plus a bounded periodic flush for long gestures and an
  orderly termination flush. Keyboard and text edits need a debounce/flush path
  too. Document the abrupt-crash loss window and preserve save-error reporting.
- If large histories still burden the writer, evaluate per-file records or a
  small transactional database later. The first fix does not require a storage
  format migration.

Publication policy needs attention alongside this change. `processRenderQueue`
drops a completed image whenever any newer request is pending and then waits
another 8 ms. Faster event handling can expose this starvation more clearly by
allowing more input events through. Use monotonic completed revisions within the
same document/source/geometry generation, with the final exact edit guaranteed
after release. This scheduling behavior is established by inspection; no new
live-frame-cadence measurement was made here.

## 2. Natural B&W can compile its point operations into a small exact table

Natural B&W reduces three input channels to an integer gray value **before**
inversion and tone processing. There are only 65,536 possible gray values at
that boundary. The subsequent point operations can therefore be compiled into
a lookup table, retaining the same intermediate UInt16 rounding boundaries.

The prototype composes the production inversion response with the production
post-inversion tone/curve path, then applies the resulting table to the input's
weighted gray values. The zero-light mask still depends on the maximum original
channel and is applied separately. Three UInt16 outputs per gray preserve small
channel differences from matrix arithmetic and rounding; assuming one output
channel would be an additional change.

| Case | Compared components | Different components | Maximum error |
|---|---:|---:|---:|
| Natural inversion | 196,608 | **0** | **0** |
| Exposure, brightness, contrast, highlights, shadows, and master curve | 196,608 | **0** | **0** |
| Legacy gamma/shadow/highlight controls after Natural inversion | 196,608 | **0** | **0** |

The source combines deterministic varied BGR values with values around the
zero-light threshold. Every case includes measured medians and pre-inversion
exposure. This verifies the prototype in those cases; it does not certify every
saved setting, profile, geometry path, or GPU implementation.

The table is **393,216 bytes, or 384 KiB**. Applying it took 0.23–0.34 ms on the
65,536-pixel input. Building it took 7.67–14.00 ms, while the ordinary reference
render took 0.84–8.11 ms. Therefore **building a fresh table for this small image
was slower overall**. The opportunity is amortization over large images and
reuse, not a demonstrated end-to-end speedup.

This targets a major allocation in the CPU Natural path: semantic tone edits
currently expand the whole image into three Double channels. That one buffer
is about **920 MiB at 7752 × 5184**. An exact table plus one pixel pass can avoid
that particular full-frame intermediate. Geometry and final output still need
their own storage and work.

The next implementation should separate the inversion-table key
(profile, measured medians, pre-inversion exposure) from the tone/curve key.
Build only the latest requested table in a worker and use a small bounded cache.
Choose the ordinary path for small images when table construction cannot be
amortized. A GPU variant can store the logical 1D table in a 256 × 256 texture,
but must define point sampling, index rounding, and format explicitly.

This result concerns Natural B&W with point tone/master-curve operations and
neutral color controls. Classic's per-channel inversion occurs before grayscale
and requires a different derivation. Spatial adjustments must retain their
position before lookup application. A changed photographic curve can use the
same mechanism, but exact agreement with today's renderer and improved tonal
quality remain separate decisions.

## 3. The local curve repair works, but normalization can still erase detail

The proposed local replacement for the three flat knots produced **2,954 distinct
16-bit output levels** across the former 13,107-code plateau. The current curve
produces one. Its maximum change over the entire neutral ramp is approximately
7.49 units on an 8-bit code scale, so this is a visible look change that needs a
photographic comparison.

For input values 0.72, 0.76, 0.80, 0.84, and 0.88, the candidate produces:

```text
gain 1.00000:  8564, 7973, 7383, 6792, 6201
gain 1.43425:  4430, 4430, 4430, 4430, 4430
```

The second gain is the actual Standard B&W normalization for a measured green
median of 20,000. All five values exceed the curve's input ceiling after that
gain. Repairing the knots alone cannot repair this second loss.

The candidate also yields only **12 distinct rounded 8-bit codes** across that
interval. The current preview explicitly requests RGBA8. Once curve/range loss
is fixed, compare native-pixel TIFF output with a higher-precision or dithered
presentation experiment. A higher-precision buffer does not by itself guarantee
a higher-precision display path, and it does not repair values already clipped.

## 4. HDR weights can worsen noise even with correct alignment

The HDR merger weights each input by its original encoded-to-linear brightness:
the weight reaches 1 from 0.04 to 0.92 and decreases toward the endpoints.
It does not account for the uncertainty increase when a short exposure is
multiplied to the reference scale.

Consider a constant true reference-relative signal of 0.8 and captures at
0, −2, and −4 EV. Their nominal observed signals are 0.8, 0.2, and 0.05, so all
receive weight 1. Under a shot-noise variance model, the normalized short
exposures have variances proportional to 1, 4, and 16.

Equal weighting gives variance `(1 + 4 + 16) / 9 = 2.333` times the longest
capture's variance. Ideal inverse-variance weighting gives
`1 / (1 + 1/4 + 1/16) = 0.762` times that variance.

The production probe uses all eight independent sign combinations of small
normalized errors ±0.001, ±0.002, and ±0.004. It supplies exact exposure offsets
and alignment; no source clips. The perturbations stay within the robust
merger's rejection threshold. After the real transfer tables and merge, the
**mean squared error is 2.372 times that of the longest capture**.

This is a constructed counterexample, not a measured improvement/degradation on
the owner's camera. It proves that three captures are not guaranteed to improve
the current merge merely because the images align and have usable brightness.

The research direction is confidence weighting that combines saturation,
registration reliability, and exposure-normalized variance. For a simple
fixed-gain camera model `variance(y) = a × y + b`, scaling an observation by
`1 / exposure` scales its variance by `1 / exposure²`. Estimate the noise model
from suitable repeated flat/dark captures or camera data, rather than assigning
weights solely by midtone brightness. Developed RGB has correlated noise after
demosaicing and color conversion, so a RAW-domain model cannot be transplanted
unchanged into this sRGB merge.

[Hasinoff, Durand, and Freeman's noise-optimal HDR capture work](https://people.csail.mit.edu/hasinoff/hdrnoise/)
is relevant because it treats capture decisions through an explicit camera
noise model. It does not justify prescribing a particular ISO or bracket spacing
for this scanner without measurements. This pass does not alter capture advice
or merge defaults.

## 5. Preserve HDR in bounded storage, with the right signal meaning

`StoredScanStack` already spools captures and merges row bands. A Float32 merge
need not keep three full floating-point frames. At the same 7752 × 5184 size:

| Buffer | Storage |
|---|---:|
| One full BGR UInt16 image | 230 MiB |
| One full BGR Float32 image | 460 MiB |
| One full BGR Double image | 920 MiB |
| One BGR Float32 band of 256 rows | 22.7 MiB |

These are array payloads, not peak memory estimates. Inputs, temporary Data
copies, output, alignment data, graphics resources, and halos are additional.
The current three-source band limit gives roughly 120 rows at this width, so
actual band sizes should continue to follow a byte budget and capture count.

There are useful implementation steps:

1. Separate geometry reference from photometric exposure scale. Preserve a
   selected anchor's coordinate system without using its white limit as the
   dynamic-range ceiling.
2. Give pre-inversion linear negative data its own typed contract, including
   exposure scale, color basis, black/clear calibration, and sample validity.
   `RenderReadyLinearImage` contains the **positive** after inversion in a
   Rec.2020 working basis. It is not interchangeable with negative radiance.
3. Add a band consumer after `mergeRows` that can receive unclipped values before
   `StackTransfer.encode`. For export, merge/invert/adjust a bounded region before
   final integer encoding. Preserve global analysis and existing geometry order.
   Rotation/perspective require source regions and halos; arbitrary warps are
   not solved merely by changing the scalar type of a scanline.
4. For editable HDR sources, retain a bounded cache or temporary tiled backing
   of the merged negative, rather than baking the selected look into the only
   retained pixels. Budget the decoded inputs and graphics backing as well.
5. Once registration is complete, consider releasing the full reference pixels
   before merging. `finish` currently keeps them alive although its subsequent
   uses are dimensions/component count; metadata can survive separately. This
   could remove one 230 MiB resident payload during that phase, subject to an
   ownership check of the decoder/caller too.

Both `FilmNegativeProcessing.sRGBToLinear` and `linearToSRGB` clamp to 0–1.
Passing a new floating buffer through those existing helpers would silently
reintroduce the loss. The extended-range path needs deliberate transfer/range
handling, rather than just replacing UInt16 with Float32.

The small precision sweep also rejects Float16 as an automatic export-precision
upgrade. It round-trips every 16-bit encoded gray through linear storage and
back, within the unit interval:

| Method | Distinct outputs from 65,536 inputs | Changed codes | Maximum code error |
|---|---:|---:|---:|
| Current production merge | 46,719 | 18,817 | 6 |
| Direct transfer calculation | 65,536 | 0 | 0 |
| Interpolated 4,096-interval Double lookup | 65,526 | 839 | 1 |
| Linear Float16 storage | 10,871 | 54,665 | 10 |
| Linear Float32 storage | 65,536 | 0 | 0 |

The interpolated table uses 32,776 bytes and is an interesting replacement for
the current rounded linear index. The one-code bound applies to this finite
ramp test; it is not a bound on every possible merged radiance or proof of GPU
arithmetic. Direct evaluation is the accuracy reference. A new implementation
must measure cost and validate its intentional differences from existing exports.

Apple recommends Float16 for many HDR rendering workloads in
[Metal for Pro Apps](https://developer.apple.com/videos/play/wwdc2019/608/).
That is compatible with using it for a display surface, but it does not establish
exact 16-bit editing/export preservation in this pipeline. Storage range,
relative precision, and final display precision are different requirements.

## 6. Reduce visible work without changing the small details being judged

At present, Core Image receives encoded UInt16 values with color management
disabled, and the custom kernel performs its own transfers. Enabling ordinary
automatic color management would change the inputs expected by the inversion
curve. Apple's [Core Image guide](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/CoreImaging/ci_performance/ci_performance.html)
documents both the default linear-light processing and the unmanaged alternative.

Resampling also needs an explicit order. For the current B&W curve and scan
values 0.6 and 0.9, correcting each pixel and averaging the encoded outputs gives
0.1317665. Averaging the inputs first and correcting gives 0.105823: a difference
of **6.62 units on an 8-bit code scale**. This two-pixel calculation demonstrates
noncommutativity; it does not model a particular scaling filter or display.

Use a full-source correction followed by a defined downsample as the comparison
reference for Fit rendering. Evaluate cheaper input pyramids against it with
fine dark details and film grain. Keep native-pixel inspection on full-resolution
source regions, and keep medians/profile analysis stable across zoom levels.
The exact B&W lookup offers one way to make correct-order processing cheaper.

Before assuming that a smaller destination or a rewritten shader removes work,
capture a single Core Image graph with `CI_PRINT_TREE`. Apple's
[debugging session](https://developer.apple.com/videos/play/wwdc2020/10089/)
describes inspecting regions of interest, concatenated programs, and intermediate
buffers. Start with graph output only; dumping all full-image intermediates
would defeat the low-memory investigation. No Core Image graph capture was run
in this pass.

## Next implementation order

1. Move encoding/persistence out of the event handler, bound queued deltas, and
   test revision ordering, failures, undo/reset, flush, and relaunch. Measure a
   live drag using the representative history size.
2. Add the Natural B&W table path behind an explicit dispatch condition, with
   current CPU output as the oracle. Check geometry, both monochrome profiles,
   saturation endpoints, hidden/inherited settings, and rapid table invalidation.
   Measure a retained large image once compute is available.
3. Evaluate the curve candidate on the affected crop, including normalization
   headroom. Keep its quality decision separate from the exact lookup optimization.
4. Correct merge precision/range and evaluate exposure-aware uncertainty weights
   on one retained bracket set. Then assess fractional registration.
5. Prototype GPU-visible-region rendering with documented resampling and
   precision. Revisit a Metal demosaic after these avoidable losses/workloads.

A longer-term reference for joint HDR and spatial reconstruction is
[Lecouat et al., High Dynamic Range and Super-Resolution from Raw Image Bursts](https://arxiv.org/abs/2207.14671).
It combines a physical image-formation model with learned components, so it is
a research reference rather than an immediate dependency or a battery-light
drop-in replacement. The local counterexamples should be resolved before a
much larger reconstruction project is used to judge the remaining quality gap.
