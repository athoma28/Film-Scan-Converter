# B&W fine tonality and three-scan reconstruction

September 13, 2026. Source investigation of `4e962c1` plus the working tree,
and small synthetic probes against the existing release engine. No RAW corpus
decode, Camera Raw comparison, or photographic profile refit was run.

The reported symptom is a distant person's eyebrow looking flat or painted on
at high zoom: the contour survives, but the tonal transition from its center to
its edge disappears. Camera Raw preserves more of that transition, and a
three-exposure HDR merge in Camera Raw looks better still.

**There is a confirmed mechanism in the default Natural / Standard B&W curve
that can cause exactly this kind of loss.** It maps a substantial interval of
different scan values to one dark gray. Whether the reported photograph lands
in that interval remains unconfirmed: the particular file, conversion mode,
settings, preview tier, and matched export comparison have not been identified.
Classic and the Shanghai GP3 alternate do not use this particular flat curve.

Follow-up: the [second research pass](research-pass-two-2026-09-13.md) evaluates
the local curve candidate, shows why normalization can still clip it, and adds
an HDR noise-weighting counterexample and an exact B&W processing prototype.

## 1. A flat interval in the default B&W conversion

The generic calibrated monochrome profile contains these eleven equally spaced
knots, at inputs 0.0, 0.1, …, 1.0:

```text
0.989069, 0.912663, 0.668040, 0.603132, 0.488223, 0.330530,
0.157710, 0.105823, 0.105823, 0.105823, 0.067593
```

Three identical knots at 0.7, 0.8, and 0.9 mean **zero local contrast throughout
0.7–0.9**. The interpolation is linear. This is information loss before display
quantization, not merely too few bits in the preview.

| Input after normalization | Natural / Standard B&W output | Natural / Shanghai GP3 output |
|---:|---:|---:|
| 0.70 | 0.105823 | 0.140077 |
| 0.75 | 0.105823 | 0.136043 |
| 0.80 | 0.105823 | 0.132008 |
| 0.85 | 0.105823 | 0.112271 |
| 0.90 | 0.105823 | 0.092534 |

These are encoded channel values, not percentages of physical luminance. For
this table the curves receive the same normalized input; an actual frame's
normalization differs between the two profiles.

The [small production-code probe](../../native/diagnostics/BWTonalityProbe.swift)
passes a 256 × 256 neutral UInt16 ramp through `FilmProcessing.correctedPreview`
with B&W defaults, no measured median (gain 1), and no other adjustments.
For source codes **45,875–58,981**, the result is:

- **Standard B&W: 13,107 distinct inputs → one output code, 6,935.**
- Shanghai GP3: the same inputs → 3,117 distinct output codes, 6,064–9,180.

The [recorded JSON](bw-tonality-probe-2026-09-13.json) includes the complete
results. The [runner instructions](../../native/diagnostics/README.md) reuse a
current release build and compile only the probe.

Source locations under `native/FilmScanEngine/Sources/`:

- `FilmScanEngine/FilmNegativeProcessing.swift`:
  `genericCalibratedMonochrome`, `calibratedMonochromeInputGain`,
  `applyCalibratedMonochromeInversion`, `calibratedCurveValue`.
- `FilmScanPreviewRenderer/StillPreviewRenderer.swift`:
  `calibratedMonochromeKnot` and `calibratedMonochromeCurve` repeat the same
  constants and interpolation in the GPU kernel. The GPU plateau is established
  by inspection; this new probe runs the CPU path.
- `FilmScanEngine/Processing.swift`: the Natural B&W inversion happens before
  semantic tone adjustments and the user curve.
- `FilmScanConverterMac/AppModel.swift`: `makeExportRequest` calls the same
  UInt16 correction function before writing the export. Thus choosing a 16-bit
  TIFF cannot recover the discarded distinctions. No TIFF writer was exercised
  in this probe.

The actual curve input is approximately:

```text
clamp(encoded gray × profile input gain × 2^monochromeExposureEV, 0, 1)
```

For Standard B&W, the input gain is `28685 / measuredGreenMedian` when a median
is present. Consequently, “0.7–0.9” does **not** mean a fixed 70–90% interval in
every original scan. The affected tones move with exposure and the frame's
median. There is additional collapse wherever this normalized input exceeds 1.

A dark feature in the positive corresponds to relatively transparent film and
a bright scan signal. Different eyebrow interior/edge values can therefore land
in the flat interval while the surrounding skin remains outside it. The shape
survives but its interior becomes uniform. This is a causal explanation of what
the curve can do, not a finding about an unexamined photograph.

Once these values are equal, downstream Exposure, Contrast, Shadows, or Curves
cannot distinguish them. More output bits and a different interpolation of the
same flat knots cannot restore them either. A pre-inversion exposure change may
move them out of the interval, but also changes the rest of the image.

## 2. Why calibration can allow this, and how to replace it

`FilmScanReferenceCalibrator/main.swift` fits eleven-point curves against sampled
reference JPEG pixels. Its `monotoneDecreasing` function pools violating adjacent
blocks into equal values. The constraint prevents reversals but permits flat
intervals. This is a mechanism capable of creating a plateau; the exact original
fit that produced the shipped generic B&W constants was not established here.

Whole-image mean absolute error can reward matching the overall dark region
while failing to preserve a tiny eyebrow transition. “Monotone” alone is not an
adequate detail-preservation criterion.

The replacement experiment should:

1. Bound the negative slope away from zero over useful, unclipped negative
   densities, with explicit handling of the endpoints and normalized headroom.
   Choose a meaningful contrast bound; an infinitesimal slope can still quantize
   an entire useful interval to one output code.
2. Fit a smooth, shape-preserving response with this constraint. A spline alone
   does not repair repeated knots, and an unconstrained spline can overshoot.
3. Score small tonal transitions as well as overall rendering: local gradient
   retention, plateau lengths, clipping fractions, and selected feature crops.
   Preserve tonal ordering without simply amplifying grain and sensor noise.
4. Keep an explicit version of the old rendering so saved edits remain
   reproducible. Evaluate the candidate before changing the default. Both CPU
   and GPU must use the same profile definition or generated LUT.

A first candidate does not require a corpus-wide refit: retain the existing
0.6 and 1.0 anchors and interpolate through the flat region. That gives candidate
knots **0.13518075, 0.11265150, 0.09012225** at 0.7, 0.8, and 0.9. This is a
simple controlled contrast-restoration experiment, not a calibrated replacement
or a recommended new default. Compare its overall shadow appearance and local
detail against the unchanged profile before considering a broader constrained fit.

The GP3 profile is useful as an immediate **diagnostic comparison**, not proof
that it should become the universal default. The existing
[reference calibration record](../development/reference-negative-calibration.md)
reports six B&W references, with GP3's held-out error at 0.143 versus 0.137 for
the generic curve. Its nicer slope in this interval and its overall reference
match are separate questions. No new default or photographic look was changed
during this investigation.

## 3. What three captures can improve—and what FSC currently loses

Repeated captures can reduce independent camera noise. In the ideal equal-noise,
equal-exposure average, three frames reduce noise standard deviation to
`1 / sqrt(3)` of a single frame, about 4.77 dB improvement in signal-to-noise
ratio. This ideal calculation does not apply unchanged to unequal HDR weights
or correlated noise. Film grain is part of the same stationary negative; it is
not independent camera noise that disappears just because it is photographed
three times.

Bracketed exposures can also provide an unclipped, better-exposed measurement
where one capture is poor. Adobe documents exposure-bracket merging, alignment,
deghosting, and automatic tone settings in its
[Lightroom HDR merge guidance](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/hdr-photo-merge.html).
Those settings should be controlled in a comparison. The
[Camera Raw team's HDR explanation](https://blog.adobe.com/en/publish/2023/10/10/hdr-explained)
also distinguishes merging a wider-range source from displaying it on an HDR
screen. Better B&W detail from a merged source does not require a brighter HDR
display.

FSC's `MultiScanStacker` starts with separately decoded, display-encoded UInt16
sRGB images. `StackTransfer` inverse-linearizes those values, then `mergeRows`
exposure-normalizes them to the **first image** and combines them. This is
linear-light merging, but it is downstream of demosaicing, camera color
processing, and the decoder's range limits.

There are three concrete limitations in `FilmScanEngine/ScanStacking.swift`:

| Mechanism | Consequence | Evidence |
|---|---|---|
| `StackTransfer.encode` clamps merged linear radiance to 0–1. | Detail recovered above the reference's white limit is discarded before inversion. | Source and tiny production merge probe. |
| Encoding first rounds to a uniformly spaced 16-bit **linear** lookup-table index. | An extra quantization step is inserted before encoded UInt16 storage; the darkest scan values have particularly coarse spacing. | Source and identical-image merge probe. |
| `ScanStackAlignment` stores only integer X/Y translations. | Fractional residual shifts can soften small features when averaged. There is no subpixel reconstruction. | Source; no photographic blur measurement here. |

The HDR probe uses four true reference-relative radiances: 1.05, 1.20, 1.40,
and 1.60, captured at offsets 0, −1, and −2 EV. It supplies exact exposure offsets
and perfect identity alignment to isolate range handling. Both shorter captures
retain all four measurements. With the brightest capture first, the merged
outputs are **65,535, 65,535, 65,535, 65,535**. With the shortest capture first,
they are **35,996, 38,261, 41,038, 43,593**, now on that capture's exposure scale.
Changing reference order did not create new information; it changed whether the
existing information fit in the current representation.

The precision probe merges three identical, noiseless images containing codes
0–50. It returns only five unique codes: 0, 13, 26, 39, and 52. This is a confirmed
precision loss, but its location in *dark scan* values makes it a weaker direct
explanation for *dark positive* eyebrows than the B&W curve and highlight
headroom problems.

Selecting a shorter reference can avoid the first fixture's merge clipping, but
does not solve the architecture: subsequent median normalization can still drive
values into the flat curve or its input clamp. Nor can an improved merge help
if the next stage maps all of its recovered distinctions to one gray.

The preferred research path is to preserve exposure scale and unclipped linear
radiance through capture normalization and negative inversion, then apply the
display response. Prototype Float32 on small regions or row bands; do not infer
that Float16 automatically gives more precision than the current UInt16 around
midtones. Keep sensor saturation/validity information separate from the developed
RGB image. A later RAW merge can avoid some losses that already occurred while
developing the individual captures.

## 4. Demosaicing, detail filtering, and B&W-specific reconstruction

Other plausible contributors should be separated after the curve loss is
removed from the comparison:

- `CLibRawShim/RawTherapeePipeline.cpp::isoAdaptiveFilter` applies mild sharpening
  below ISO 800, but horizontal recursive smoothing at ISO 800 and above. Its
  blend increases from 0.20 to 0.38 at ISO 3200. The smoothing is not edge-aware
  and can flatten tiny features. For ordinary low-ISO scans, this smoothing
  branch is not the leading suspect. Disabling it for one cached crop is a cheap
  comparison before designing another denoiser.
- Draft/inspect/full preview resolution and full-preview versus export demosaic
  quality must be identified. Compare native-pixel crops after the full RAW tier
  has loaded, and compare the 16-bit export independently. Enlarging a draft or
  changing display interpolation can mimic a reconstruction problem.
- Camera Raw exposes sharpening radius, detail, masking, and luminance noise
  detail/contrast controls. Each can affect an eyebrow's apparent transition.
  Its [official detail-processing documentation](https://helpx.adobe.com/ca/camera-raw/desktop/using/sharpening-noise-reduction-camera-raw.html)
  recommends judging these controls at least at 100% zoom. Compare a neutral
  detail setting first, then the preferred edited result; the latter includes
  aesthetic processing as well as reconstruction.

An especially relevant longer-term experiment is **B&W-aware reconstruction of
the CFA samples**. For a sufficiently neutral negative under stable light, a
calibrated photosite measurement can be modeled as a channel sensitivity times
one underlying scalar film transmittance, plus black offset and noise. Instead
of reconstructing three full color planes and discarding their color later, test
reconstructing that scalar signal directly with noise-aware weights.

This is a proposed model, not an implemented decoder or a claim that a color
sensor becomes a monochrome sensor. CFA sensitivities, illumination, film base,
staining, channel clipping, optical blur, and spatial calibration still matter.
The test needs a small real RAW region with sufficient neighboring context,
dark/flat calibration, and a comparison against ordinary demosaic + grayscale.
If those assumptions hold, it could improve both detail retention and work per
pixel, making it relevant to the Metal decode research as well.

For three-frame detail recovery, fractional registration comes before any
super-resolution claim. Google's
[Handheld Multi-Frame Super-Resolution paper](https://research.google/pubs/handheld-multi-frame-super-resolution/)
demonstrates joint reconstruction from shifted CFA captures. It is a useful
research direction, not evidence about Camera Raw's undisclosed merge internals
or a drop-in solution for this app's X-Trans path. Three stationary, identically
sampled captures do not automatically provide new spatial samples. Film motion,
fractional shifts, interpolation blur, and rejection of misregistered regions
all need explicit handling.

## 5. A low-compute order of experiments

1. Identify one representative eyebrow crop, the conversion profile, and whether
   the effect survives full-resolution TIFF export. Record its normalized input
   values and what fraction fall inside the plateau or above the input clamp.
   Decode each source once and retain the decoded data for subsequent trials.
2. Reprocess the same data through the current curve, GP3, Classic, and a
   constrained candidate. Keep normalization explicit, and keep the original
   full-frame medians when processing a crop. Recomputing the median from just
   the eyebrow would change the experiment.
3. Compare line profiles across the eyebrow center and edge, a matched native
   pixel crop, local contrast, clipping, and flat-region length. Add a smooth
   ramp and a low-contrast edge fixture. Evaluate grain separately so sharper
   noise does not win the quality comparison.
4. Use a single three-capture set to compare reference order, unclipped merge
   storage, and fractional registration. Reuse decoded inputs. Check exposure
   normalization against source clipping rather than relying on visual brightness.
5. Only then compare demosaic/detail-filter variants or prototype scalar CFA
   reconstruction. Preserve a border around test regions and full-frame exposure
   statistics; a RAW crop is not necessarily equivalent to cropping after decode.

This investigation shifts the B&W quality priority toward preserving existing
tonal information. The related
[decode/edit/export performance plan](research-directions-2026-09-12.md) remains
applicable, but making the same flat conversion faster would not resolve this
specific loss.
