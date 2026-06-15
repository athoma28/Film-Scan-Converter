# Film Processing Research: Practical Film-Specific Negative Inversion for Camera-Scanned Film

## Executive summary

Film Scan Converter should not jump directly from “simple inversion” to a fully film-stock-specific color-science engine. The fastest path is a sequence of small, visible wins:

1. Make the input stable: normalize camera raw captures against black level, flat field, and backlight.
2. Move inversion into optical-density space.
3. Estimate and subtract the film base/orange mask in density space.
4. Add roll-level consistency so every frame is not independently reinterpreted.
5. Add a generic negative curve that produces good output before stock profiles exist.
6. Add per-stock characteristic curves.
7. Add camera/backlight profiles.
8. Fit per-stock color matrices from the reference library.
9. Add optional residual 3D LUTs only after the physical pipeline is working.

The key new constraint is that the input is not a scanner. It is a Fujifilm camera photographing film on a backlight. That means the “scanner RGB” assumption is too optimistic. The actual capture is a combined system:

[
\text{capture system} =
\text{backlight spectrum}

* \text{film spectral transmittance}
* \text{lens}
* \text{Fujifilm sensor filters}
* \text{raw conversion}
  ]

So Film Scan Converter should treat every conversion as dependent on a **capture profile**:

[
\text{profile} =
(\text{camera}, \text{lens}, \text{backlight}, \text{raw settings}, \text{film stock})
]

The app can still work without perfect profiling, but the architecture should not pretend that Portra 400 has one universal RGB inversion independent of the capture setup.

---

# Step 1 — First win: enforce linear input

## Goal

Before film physics, the app needs trustworthy linear data. A raw photo of a negative must be treated as a measurement of transmitted light, not as a normal photograph.

## Requirement

The input to the inversion pipeline should be linear RGB or scene-linear working RGB with no contrast curve, no auto tone, no baked white balance, no film simulation, and no JPEG-like processing.

For each raw channel (c \in {R,G,B}), define:

[
S_c(x,y)
]

as the raw or linearized pixel value at position ((x,y)).

Then subtract camera black level:

[
S'_c(x,y) = S_c(x,y) - B_c
]

where (B_c) is the per-channel camera black level.

Clamp safely:

[
S'_c(x,y) = \max(S'_c(x,y), \epsilon)
]

## Why this is a win

This alone reduces a huge class of inconsistent results. If one scan is converted from raw with auto white balance and another with a different camera profile or tone curve, no inversion model will behave predictably.

## Developer task

Add an import diagnostic panel:

* Show whether the image is raw, TIFF, or JPEG.
* Show whether values appear clipped.
* Show per-channel histograms.
* Warn when the input is probably nonlinear.
* Prefer raw or 16-bit linear TIFF.

## Acceptance test

Photograph the same negative twice with the same exposure. The linearized values should match except for noise and slight alignment changes. If the same capture looks different because of auto white balance, the app should flag it.

---

# Step 2 — Second win: flat-field and backlight normalization

## Problem

With camera scanning, the backlight is often not uniform, not spectrally neutral, and not stable. A scanner has a controlled illumination path. A cheap LED pad, tablet, RGB panel, or Neewer light does not.

The camera does not record “red dye,” “green dye,” and “blue dye.” It records:

[
S_c(x,y)
========

B_c
+
G_c(x,y)
\int_{\lambda}
L(\lambda, x,y)
T_{\text{film}}(\lambda, x,y)
Q_c(\lambda)
d\lambda
]

Where:

* (B_c) is camera black level.
* (G_c(x,y)) is lens shading / vignetting / pixel gain.
* (L(\lambda, x,y)) is the backlight spectrum at wavelength (\lambda).
* (T_{\text{film}}(\lambda, x,y)) is film transmittance.
* (Q_c(\lambda)) is the Fujifilm camera channel sensitivity.
* (c) is the camera channel.

Because (L(\lambda)) changes by backlight, the same negative can produce different RGB values even with identical exposure.

## Practical normalization

Capture a blank backlight frame with no film:

[
F_c(x,y)
========

B_c
+
G_c(x,y)
\int_{\lambda}
L(\lambda, x,y)
Q_c(\lambda)
d\lambda
]

Then estimate film transmittance per channel:

[
T_c(x,y)
========

\frac{S_c(x,y)-B_c}{F_c(x,y)-B_c}
]

Clamp:

[
T_c(x,y) = \operatorname{clamp}(T_c(x,y), \epsilon, 1)
]

This is the first essential math change. It makes the input a relative transmittance image rather than a raw photo of a glowing object.

## If no blank frame is available

Use a fallback, in order:

1. Use stored flat-field calibration for the same camera/lens/backlight.
2. Estimate illumination falloff from film rebate and border regions.
3. Use robust large-scale blur of the negative as a weak correction.
4. Disable flat-field correction and warn that color consistency will be limited.

## Developer task

Add a “Capture Session” object:

```swift
struct CaptureSessionProfile: Codable {
    let cameraModel: String?
    let lensModel: String?
    let backlightName: String?
    let rawConverterVersion: String?
    let blackLevel: SIMD3<Float>
    let flatFieldImageURL: URL?
    let clearBacklightRGB: SIMD3<Float>
    let createdAt: Date
}
```

## Acceptance test

Photograph the same negative in the center and near a corner of the backlight. After flat-field correction, the converted image should not show a major brightness or color shift from position alone.

---

# Step 3 — Third win: convert transmittance to optical density

## Goal

Stop thinking in RGB subtraction. Film is an absorbing medium. Absorption is additive in density, not in linear RGB.

For each channel:

[
D_c(x,y) = -\log_{10}(T_c(x,y))
]

Because:

[
D = \log_{10}\left(\frac{1}{T}\right)
]

where (T) is transmittance.

## Why this matters

If the film base transmits only 25% of blue-channel light and 70% of red-channel light, the right correction is not:

[
S_c - \text{mask}_c
]

The more physical correction is:

[
D_{\text{image},c}
==================

D_c - D_{\text{base},c}
]

which is equivalent to:

[
D_{\text{image},c}
==================

-\log_{10}(T_c)
+
\log_{10}(T_{\text{base},c})
]

[
D_{\text{image},c}
==================

\log_{10}
\left(
\frac{T_{\text{base},c}}{T_c}
\right)
]

So the mask correction is:

* multiplicative/divisive in transmittance;
* subtractive in density;
* not additive in RGB.

## Developer task

Replace the current inversion core:

```swift
out = 65535 - in
```

with:

```swift
let T = clamp((S - black) / (flat - black), epsilon, 1.0)
let D = -log10(T)
```

At this step, do not yet worry about perfect color. Just display the density image and verify that it behaves sensibly.

## Acceptance test

A clear film rebate should have nearly zero image density after base subtraction. Dense negative areas should have higher density. The math should not change if the camera exposure is raised or lowered, as long as nothing clips and the flat field is captured at the same exposure.

---

# Step 4 — Fourth win: estimate film base/orange mask in density space

## Goal

Find:

[
D_{\text{base},c}
]

for the current roll, frame, or stock.

This represents base + fog + orange mask as seen by the current camera/backlight system.

## Best case: visible rebate

If the scan includes unexposed film border, compute:

[
T_{\text{base},c}
=================

\operatorname{median}_{(x,y)\in R}
T_c(x,y)
]

where (R) is the detected rebate region.

Then:

[
D_{\text{base},c}
=================

-\log_{10}(T_{\text{base},c})
]

Use the median or trimmed mean, not the average, because dust and scratches are common.

## Frame without rebate

Use roll-level memory:

[
D_{\text{base},c}^{\text{roll}}
===============================

\operatorname{median}
\left(
D_{\text{base},c}^{(1)},
D_{\text{base},c}^{(2)},
...,
D_{\text{base},c}^{(n)}
\right)
]

Then apply to all frames from the roll.

## No rebate anywhere

Use stock default plus user correction:

[
D_{\text{base},c}
=================

D_{\text{base},c}^{\text{stock, capture}}
+
u_c
]

where (u_c) is the user’s manual base correction.

## Important design point

Do not make the orange mask purely per-frame unless necessary. Per-frame automatic base estimation creates the classic failure where every image from a roll has a slightly different color personality.

Preferred hierarchy:

[
\text{measured roll base}

>

\text{measured frame base}

>

\text{stock + capture default}

>

\text{manual picker}
]

## Developer task

Add base estimation as a standalone feature with a visible diagnostic:

* overlay detected rebate;
* show measured base RGB;
* show measured base density;
* show confidence;
* allow user to click a rebate area manually;
* allow “apply to roll.”

## Acceptance test

Scan five frames from one roll with the same setup. The base estimate should be nearly constant. If it jumps significantly, the app should either reject the estimate or lower confidence.

---

# Step 5 — Fifth win: produce a good generic inversion before per-stock profiles

## Goal

Before chasing Portra-vs-Ektar fidelity, build a generic negative inversion that is already better than simple RGB inversion.

After base subtraction:

[
D'_{c}(x,y)
===========

\max(D_c(x,y) - D_{\text{base},c}, 0)
]

For a negative, higher scene exposure produces higher negative density. So a first scene estimate is:

[
\log E_c(x,y)
=============

a_c D'_c(x,y) + b_c
]

where (a_c) is a per-channel slope and (b_c) is a per-channel offset.

Then:

[
E_c(x,y)
========

10^{\log E_c(x,y)}
]

This gives a scene-linear positive estimate.

## Generic default

Start with:

[
a_R = a_G = a_B = 1
]

[
b_R = b_G = b_B = 0
]

Then normalize exposure:

[
E'_c(x,y)
=========

\frac{E_c(x,y)}
{P_{50}(E_G)}
]

where (P_{50}(E_G)) is the median green-channel scene estimate.

Then apply a display curve.

## A slightly better generic model

> **Implemented 2026-06-15:** RawTherapee's power-law inversion has been ported to Swift: `FilmNegativeProcessing.applyPowerLawInversion()`. Per-channel `output = multiplier × pixel^-(greenExp × ratio)`, auto-calibration via 20%-border-cut medians to neutral middle gray, Color Negative (1.36/1.5/0.86) and B&W (1.0/1.5/1.0) presets, CPU/GPU/Metal parity. See `native-macos.md` for status.

RawTherapee’s documented model is equivalent in spirit to channel-dependent exponents. In density terms, that means channel-dependent slopes:

[
\log E_R = a_R D'_R + b_R
]

[
\log E_G = a_G D'_G + b_G
]

[
\log E_B = a_B D'_B + b_B
]

Expose this as one main contrast value plus red/blue ratios:

[
a_G = a
]

[
a_R = a \cdot r
]

[
a_B = a \cdot b
]

This is simple, fast, and understandable.

## Developer task

Add a “Generic C-41” profile:

```swift
struct GenericNegativeProfile {
    var densitySlope: SIMD3<Float>   // a_R, a_G, a_B
    var densityOffset: SIMD3<Float>  // b_R, b_G, b_B
    var displayGamma: Float
    var exposure: Float
}
```

## Acceptance test

A well-exposed C-41 negative should produce a plausible positive with one click plus maybe a single exposure slider. It does not need to be stock-faithful yet.

---

# Step 6 — Sixth win: add a simple, robust display rendering stage

## Problem

The density-to-exposure step produces scene-linear-ish values. A display cannot show unbounded scene-linear exposure. You need a rendering transform.

Avoid making this film-stock-specific at first. Use one stable display rendering stage.

## Simple option

[
Y = \frac{X}{X + k}
]

where (X) is scene-linear RGB after exposure and white balance, and (k) controls highlight rolloff.

Add exposure:

[
X' = 2^{e} X
]

Then tone map:

[
Y = \frac{X'}{X' + k}
]

Then encode to sRGB or Display P3.

## Better option

Use a small filmic curve with:

* black point;
* middle gray;
* shoulder strength;
* toe strength;
* output gamma.

But do not overcomplicate this until the density pipeline is stable.

## Developer task

Create one shared renderer:

```swift
func renderDisplay(
    sceneRGB: SIMD3<Float>,
    exposureEV: Float,
    whiteBalance: SIMD3<Float>,
    tone: ToneParameters
) -> SIMD3<Float>
```

## Acceptance test

Changing film stock later should not break the basic exposure/tone behavior. Developers should be able to test inversion and rendering separately.

---

# Step 7 — Seventh win: model and limit noise amplification

## Problem

The log conversion is physically right, but it can amplify noise.

[
D = -\log_{10}(T)
]

The derivative is:

[
\frac{dD}{dT}
=============

-\frac{1}{T \ln 10}
]

So if the transmittance (T) is small, density noise grows:

[
\sigma_D
\approx
\frac{\sigma_T}{T \ln 10}
]

Then the inverse film curve adds more gain:

[
\log E = g(D)
]

[
\sigma_{\log E}
\approx
|g'(D)| \sigma_D
]

Combined:

[
\sigma_{\log E}
\approx
|g'(D)|
\frac{\sigma_T}{T \ln 10}
]

This gives a direct rule: noise is dangerous when (T) is small or when the inverse curve slope (g'(D)) is large.

## Practical control

Define a maximum allowed density-to-exposure gain:

[
G(D,T)
======

|g'(D)|
\frac{1}{T \ln 10}
]

If:

[
G(D,T) > G_{\max}
]

then reduce local curve slope or blend toward a safer rendering.

## Simple implementation

```swift
let densityNoiseGain = abs(curveDerivativeDToLogE) / (T * log(10))
let protection = smoothstep(gainStart, gainEnd, densityNoiseGain)
let safeLogE = compressedLogE(logE)
let finalLogE = mix(logE, safeLogE, protection)
```

## User-facing control

Name it something understandable:

* “Highlight protection”
* “Shadow color stability”
* “Noise-safe inversion”

Avoid exposing “density derivative limiter” as a normal UI term.

## Acceptance test

A dense negative highlight area should not turn into blotchy color noise. A very thin negative shadow area should not turn into unstable cyan/magenta patches because of tiny base errors.

---

# Step 8 — Eighth win: separate film-stock profiles from capture profiles

## Problem

With camera scanning, a Portra 400 profile is not enough. The same Portra frame photographed on a tablet, a cheap LED panel, and a high-CRI photo light can produce meaningfully different RGB data.

The more accurate model is:

[
\text{conversion profile}
=========================

\text{film stock profile}
+
\text{capture profile}
+
\text{roll correction}
]

## Film stock profile

This should describe the film itself:

```swift
struct FilmStockProfile: Codable {
    let id: String
    let name: String
    let process: FilmProcess // c41, e6, bw

    let defaultBaseDensity: SIMD3<Float>
    let inverseCurveR: [Float]
    let inverseCurveG: [Float]
    let inverseCurveB: [Float]

    let stockLookMatrix: simd_float3x3
    let defaultTone: ToneParameters
}
```

## Capture profile

This should describe the camera/backlight path:

```swift
struct CaptureProfile: Codable {
    let id: String
    let cameraModel: String
    let rawConverter: String
    let backlightName: String

    let blackLevel: SIMD3<Float>
    let clearBacklightRGB: SIMD3<Float>
    let flatFieldReference: String?

    let densityCorrectionMatrix: simd_float3x3
    let colorCorrectionMatrix: simd_float3x3
}
```

## Roll profile

This should describe the specific roll/session:

```swift
struct RollProfile: Codable {
    let filmStockID: String
    let captureProfileID: String

    var measuredBaseDensity: SIMD3<Float>?
    var exposureBiasEV: Float
    var whiteBalanceCorrection: SIMD3<Float>
    var notes: String?
}
```

## Why this is a major architecture win

It keeps future calibration sane. Developers can improve backlight handling without touching film stock data. They can improve Portra curves without invalidating every user’s capture setup.

## Acceptance test

Changing the backlight profile should change the correction matrix and base defaults, but not the underlying film-stock curve. Changing the film stock should change curves and look, but not the flat-field correction.

---

# Step 9 — Ninth win: per-stock characteristic curves

## Goal

Replace the generic linear density slope with per-stock inverse curves.

Manufacturer characteristic curves are usually plotted as:

[
D = f(\log E)
]

But runtime inversion needs:

[
\log E = g(D)
]

where:

[
g = f^{-1}
]

## Recommended representation

Digitize each stock’s red, green, and blue characteristic curves. Store the points:

[
(\log E_i, D_i)
]

Then build a monotonic inverse lookup table:

[
D \rightarrow \log E
]

For each channel:

```swift
struct InverseDensityCurve: Codable {
    let densityMin: Float
    let densityMax: Float
    let logExposureValues: [Float] // sampled uniformly over density
}
```

Runtime lookup:

[
u =
\frac{D - D_{\min}}{D_{\max} - D_{\min}}
]

[
j = u(N-1)
]

[
g(D)
====

(1-t)L_{\lfloor j \rfloor}
+
tL_{\lceil j \rceil}
]

where:

[
t = j - \lfloor j \rfloor
]

This is fast, stable, and avoids polynomial overshoot.

## Why not a 4th-order polynomial?

A polynomial can fit the middle of the curve but misbehave in the toe and shoulder. The toe and shoulder are where negative inversion is most fragile. If a polynomial becomes non-monotonic, the same density can map to two scene exposures, which is unacceptable.

Use splines or LUTs first. If a compact polynomial is desired later, treat it as an optimization, not the ground truth.

## Acceptance test

For every stock/channel curve:

[
g(f(\log E)) \approx \log E
]

and:

[
g'(D) \ge 0
]

over the valid density range.

---

# Step 10 — Tenth win: camera/backlight-aware crosstalk correction

## Problem

The film’s cyan, magenta, and yellow dye layers are not perfect spectral filters. The camera’s RGB channels are also not clean spectral measurements. The backlight spectrum may be peaky. Therefore the effective measured densities are mixed.

Use a 3×3 matrix in density space:

[
\mathbf{D}_{\text{corr}}
========================

A
\mathbf{D}_{\text{image}}
+
\mathbf{b}
]

where:

[
\mathbf{D}_{\text{image}}
=========================

\begin{bmatrix}
D'_R \
D'_G \
D'_B
\end{bmatrix}
]

and:

[
A =
\begin{bmatrix}
a_{RR} & a_{RG} & a_{RB} \
a_{GR} & a_{GG} & a_{GB} \
a_{BR} & a_{BG} & a_{BB}
\end{bmatrix}
]

This says, for example, that the corrected red-sensitive record may depend slightly on measured green and blue density too.

## Why density-space correction comes before curve inversion

Dye absorption is additive in density. So if channel mixing is caused by dye absorption and scanner/camera spectral overlap, density space is the more natural place to correct it.

## Calibration from reference library

For each stock and capture profile, collect matching pixels or patches:

[
\mathbf{x}*i = \mathbf{D}*{\text{image},i}
]

[
\mathbf{y}_i = \text{desired corrected density or desired log exposure}
]

If true corrected density is unavailable, fit the matrix indirectly by minimizing output error after the full pipeline.

Weighted least squares:

[
\theta =
(X^T W X + \lambda I)^{-1}
X^T W Y
]

Where:

* (X) is the matrix of input features.
* (Y) is the target output.
* (W) is a diagonal matrix of pixel weights.
* (\lambda) is a small regularization value to prevent wild matrices.

Use features:

[
X_i =
[D'_R, D'_G, D'_B, 1]
]

Then solve for:

[
Y_i =
[\log E_R, \log E_G, \log E_B]
]

or for final target linear RGB.

## Pixel weights

Do not weight every pixel equally. Use higher weight for:

* neutrals;
* skin-like colors;
* midtones;
* non-clipped pixels;
* low-noise regions;
* high-confidence aligned pairs.

Use lower weight for:

* dust;
* scratches;
* grain outliers;
* clipped regions;
* extreme shadows;
* extreme highlights;
* saturated neon colors;
* misregistered edges.

## Acceptance test

With the same film stock and backlight, a fitted matrix should improve neutral balance and reduce hue drift without needing a 3D LUT.

---

# Step 11 — Eleventh win: fit the display color matrix

After density correction and inverse curves, you have an estimated scene RGB:

[
\mathbf{E}
==========

\begin{bmatrix}
E_R \
E_G \
E_B
\end{bmatrix}
]

But these channels are still not sRGB or Display P3. Fit a color matrix:

[
\mathbf{C}_{\text{out}}
=======================

M
\mathbf{E}
+
\mathbf{k}
]

For many cases, start without the offset:

[
\mathbf{C}_{\text{out}}
=======================

M
\mathbf{E}
]

Fit:

[
M =
\arg\min_M
\sum_i
w_i
\left|
\mathbf{C}_{\text{target},i}
----------------------------

M\mathbf{E}_i
\right|^2
]

Closed form:

[
M =
(Y^T W X)
(X^T W X + \lambda I)^{-1}
]

where (X) contains predicted scene RGB and (Y) contains target positive RGB.

## Important

Fit in linear-light RGB, not gamma-encoded sRGB. If fitting in perceptual space later, use it as a validation metric or nonlinear optimization pass, not the first implementation.

## Acceptance test

A stock/capture matrix should improve color with no local artifacts. If the image gets better in some areas and worse in others, the remaining error probably belongs in a residual 3D LUT, not a more aggressive 3×3 matrix.

---

# Step 12 — Twelfth win: optional residual 3D LUT

## Goal

After the physical pipeline is good, add a residual correction LUT for stock fidelity.

The LUT maps:

[
\mathbf{C}*{\text{preLUT}}
\rightarrow
\mathbf{C}*{\text{postLUT}}
]

Use a 33×33×33 grid:

[
33^3 = 35{,}937
]

Each grid point stores RGB correction.

## Why this should be late-stage

A 3D LUT can hide many sins, but it can also overfit. If used too early, it becomes a black box that works only for one exposure range, one backlight, and one set of reference scans.

Correct order:

[
\text{flat-field}
\rightarrow
\text{density}
\rightarrow
\text{base subtraction}
\rightarrow
\text{curve inversion}
\rightarrow
\text{matrix correction}
\rightarrow
\text{3D LUT}
]

## Blendable LUT

Expose strength:

[
\mathbf{C}_{\text{final}}
=========================

(1-\alpha)
\mathbf{C}*{\text{physical}}
+
\alpha
\mathbf{C}*{\text{LUT}}
]

where:

[
0 \le \alpha \le 1
]

Default:

[
\alpha = 0.5
]

or stock-specific.

## Acceptance test

The LUT should improve held-out reference frames, not just the frames used to generate it. If held-out performance gets worse, the LUT is overfitting.

---

# Step 13 — Validation metrics

## Basic numerical metrics

Use held-out reference pairs.

For each stock/capture profile:

1. Convert negative through pipeline.
2. Align with target positive.
3. Mask dust, borders, clipped pixels, and misregistration.
4. Compare.

Use:

[
\text{RMSE}_{RGB}
=================

\sqrt{
\frac{1}{N}
\sum_i
|
\mathbf{p}_i - \mathbf{t}_i
|^2
}
]

Also use perceptual color error:

[
\Delta E_{00}
]

where (\Delta E_{00}) is a standard color-difference measure intended to better match human perception than raw RGB distance.

Track:

* median (\Delta E_{00});
* 90th percentile (\Delta E_{00});
* neutral patch error;
* skin-region error if available;
* highlight error;
* shadow error.

## Practical visual metrics

Create a regression gallery:

* same roll, multiple frames;
* same stock, different backlights;
* same stock, different exposure levels;
* difficult scenes: sunset, tungsten, fluorescent, snow, foliage, skin, underexposure.

## Acceptance test

Every pipeline change should generate a before/after report. Developers should be able to see whether a change improved general behavior or only made one example look better.

---

# Step 14 — UX plan that avoids overwhelming users

## Default mode

User chooses:

* film process: C-41, E-6, B&W;
* film stock if known;
* backlight/camera profile if known;
* one frame or whole roll.

Then the app does:

1. detect rebate;
2. estimate base;
3. apply roll profile;
4. invert;
5. set exposure;
6. render.

## Advanced mode

Expose controls in this order:

1. Base / mask picker.
2. Exposure.
3. Temperature/tint or RGB balance.
4. Contrast.
5. Highlight protection.
6. Shadow color stability.
7. Stock fidelity / LUT strength.
8. Expert density sliders.

## Important UI principle

Do not expose the internal math in the main UI. The math should produce stable defaults. Users should see controls named around photographic outcomes.

Bad control names:

* `Dmin_R`
* `Dmax`
* `logE slope`
* `density derivative clamp`

Better names:

* Film base
* Roll base
* Exposure
* Contrast
* Highlight protection
* Shadow stability
* Stock fidelity

---

# Step 15 — Implementation skeleton

## CPU preprocessing

Use CPU or Accelerate for:

* raw metadata extraction;
* black-level setup;
* histograms;
* rebate detection;
* profile loading;
* LUT generation;
* regression fitting offline.

## GPU hot path

Use Metal for the per-pixel transform:

```swift
struct InversionParams {
    var blackLevel: SIMD3<Float>
    var epsilon: SIMD3<Float>

    var baseDensity: SIMD3<Float>

    var densityMatrix: simd_float3x3
    var densityOffset: SIMD3<Float>

    var exposureEV: Float
    var whiteBalance: SIMD3<Float>

    var colorMatrix: simd_float3x3

    var toneParams: ToneParameters

    var highlightProtection: Float
    var shadowStability: Float
    var lutStrength: Float
}
```

## Kernel logic

```swift
// Pseudocode, not exact Metal syntax

S = readInputRGB()

T = clamp((S - blackLevel) / (flatField - blackLevel), epsilon, 1)

D = -log10(T)

DImage = max(D - baseDensity, 0)

DCorr = densityMatrix * DImage + densityOffset

logE.r = sampleInverseCurve(redCurve, DCorr.r)
logE.g = sampleInverseCurve(greenCurve, DCorr.g)
logE.b = sampleInverseCurve(blueCurve, DCorr.b)

scene = pow(10, logE)

scene *= pow(2, exposureEV)
scene *= whiteBalance

scene = colorMatrix * scene

scene = applyNoiseSafeCompression(scene, T, DCorr)

display = toneMap(scene)

display = mix(display, applyResidual3DLUT(display), lutStrength)

writeOutput(display)
```

---

# Recommended development roadmap

## Milestone 1: Linear capture sanity

Deliver:

* raw/linear import checks;
* black-level correction;
* flat-field correction;
* histogram diagnostics.

Result: fewer mysterious differences between tests.

## Milestone 2: Density inversion

Deliver:

* transmittance calculation;
* density conversion;
* base density subtraction;
* manual rebate picker.

Result: immediately better than `65535 - pixel`.

## Milestone 3: Roll-level consistency

Deliver:

* roll profile;
* base estimate reuse;
* apply-to-roll;
* confidence score.

Result: batches stop drifting frame to frame.

## Milestone 4: Generic C-41 profile

Deliver:

* generic density slopes;
* generic tone map;
* exposure and white balance;
* highlight/shadow protection.

Result: useful one-click conversions before stock profiles exist.

## Milestone 5: Capture profiles

Deliver:

* named backlight profiles;
* camera/lens/backlight calibration;
* stored flat fields;
* density correction matrix per capture setup.

Result: your inconsistent test setup becomes a controlled variable instead of a source of chaos.

## Milestone 6: Per-stock curves

Deliver:

* Portra 400, Portra 160, Ektar 100, Gold 200 as first profiles;
* inverse density LUTs;
* stock-specific defaults.

Result: stocks start to separate meaningfully.

## Milestone 7: Reference-library calibration

Deliver:

* matrix fitting;
* validation split;
* report generation;
* before/after gallery.

Result: objective improvement, not vibes.

## Milestone 8: Residual 3D LUTs

Deliver:

* optional 3D LUT;
* strength slider;
* held-out validation.

Result: stock fidelity layer without sacrificing explainability.

---

# Final recommendation

For Film Scan Converter, the best near-term architecture is not “film stock LUT from raw RGB to output RGB.” That would be fast, but too brittle for camera scanning with inconsistent backlights.

The better architecture is:

[
\text{capture normalization}
+
\text{density-domain inversion}
+
\text{roll base}
+
\text{generic negative model}
+
\text{stock curves}
+
\text{capture-aware matrices}
+
\text{optional residual LUT}
]

This gives developers a clean path where every milestone is useful by itself. It also matches the real capture problem: the film stock matters, but with a Fujifilm camera and variable backlights, the capture setup matters just as much.
