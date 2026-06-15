# Research Brief: Film-Specific Negative Inversion for Film Scan Converter

## Context

Film Scan Converter is a Swift desktop app that processes RAW scans of film negatives and slides. The initial "inversion" step for colour negative film was mathematically trivial: `65535 - pixel_value` (a simple per-pixel negation in 16-bit). After inversion, the same generic color adjustments (histogram equalization, gamma, shadows/highlights, saturation, white balance, RGB curves, color wheels) were applied identically regardless of film stock.

**Milestone: RawTherapee-compatible power-law inversion implemented (2026-06-15).** The inversion step has been replaced with a per-channel power-law model: `output = multiplier × pixel^-(greenExp × ratio)`. Auto-calibration via 20%-border-cut channel medians replaces the need for manual reference input and anchors the representative median to neutral middle gray. Color Negative (RedRatio=1.36, GreenExp=1.5, BlueRatio=0.86) and Black & White (all ratios=1.0) presets match RawTherapee's `Film Negative.pp3` and `Film Negative - Black and White.pp3`. The orange mask is compensated through the asymmetric channel ratios.

**We are explicitly avoiding deep learning for this project.** The goal is a deterministic, math-based, performant Swift implementation. No CNNs, no models, no training.

**We have access to a large curated library of "target-fidelity" scans from many different film stocks.** These are high-quality positive references paired with their corresponding raw negative scans. This library is useful for calibration (fitting parameters, generating LUTs, validating output) but will not be used for training neural networks.

## Goal

Build a film-specific inversion pipeline in Swift that is:

1. **Purely algorithmic** — every step is a deterministic mathematical transform.
2. **Physically grounded** — based on the actual physics of C-41 film, not heuristics.
3. **Per-film-stock calibrated** — parameters derived from manufacturer datasheets and/or our reference scan library.
4. **Fast** — must process hundreds of frames per batch on consumer hardware.
5. **Controllable** — users can override parameters and blend auto/manual.

The ideal outcome:

1. Manual or automatic film stock selection that applies stock-specific inversion.
2. Proper orange mask compensation — not a histogram offset hack, but actual compensation for the dye coupler layer.
3. Per-stock characteristic curves that map negative densities to colorimetrically plausible output.
4. Output that preserves the film stock's native look (Portra looks like Portra, Ektar like Ektar).

## Constraint: No Deep Learning

No CNNs, no transformers, no gradient descent at runtime, no learned model weights shipped with the app. The reference scan library may be used for offline fitting/calibration as long as the result is a set of deterministic parameters (curves, matrices, LUTs) that ship with the app as data — not as a trained model.

## Questions to Investigate

### 1. The Physics: What Actually Happens in a C-41 Negative?

We need a solid understanding before any algorithm design. Key questions:

- **What is the orange mask made of?** Dye couplers that form the cyan, magenta, and yellow dyes are themselves colored. The mask is not uniform — it varies by channel and depends on exposure. How does it actually interact with scanner RGB? Is it an additive offset? A multiplicative factor? Something nonlinear that depends on density?
- **The D-log E curve**: Film manufacturers publish characteristic curves (density vs. log exposure) for each channel. What is the functional form? Is a 4th-order polynomial fit per channel adequate? Can these curves be extracted from datasheets (Kodak H-1, Fuji datasheets)?
- **Scanner response**: A typical CCD scanner captures linear sensor values. These are not densities — they're transmittance measurements. What is the correct mapping from scanner RGB → negative dye density → scene exposure → display-referred color?
- **C-41 vs. E-6**: Is slide film processing just "no inversion needed" or are there E-6-specific color shifts that should be compensated?

Key sources: Kodak publication H-1, C-41 process specifications, Fuji datasheets, Hunt's "The Reproduction of Colour", Giorgianni & Madden's "Digital Color Management".

### 2. Orange Mask — How Is It Actually Handled?

The orange mask is the central problem. Explore every known approach:

- **Subtractive model**: Treat the mask as a fixed per-channel offset (RGB) that is subtracted before inversion. Is this adequate? Darktable's negadoctor uses this — what are its limitations?
- **Multiplicative model**: Treat the mask as a density that varies with the underlying image. If it's formed by unreacted dye couplers, it should decrease where density is high (more couplers were used to form image dye).
- **Per-channel percentile method**: Darktable's negadoctor finds the channel minima/maxima from the negative rebate (unexposed film border) and uses those as the mask color. How robust is this? Can we detect the rebate reliably from arbitrary scans?
- **ColorPerfect approach**: Reportedly uses a fixed per-stock color matrix derived from measuring known test targets on each film stock. What is the actual math?
- **Spectral approach**: The orange mask has a known spectral absorption curve. If we have scanner spectral sensitivity data, can we compute a principled compensation? (Likely impractical without a spectrophotometer, but worth understanding.)

Key search terms: `darktable negadoctor algorithm`, `colorperfect plugin method`, `orange mask compensation color science`, `C-41 dye coupler mask physics`

### 3. Per-Stock Characteristic Curves

Each film stock has its own D-log E curves (one per dye layer: cyan, magenta, yellow). These define how scene exposure maps to negative density.

- **Datasheet extraction**: Can we digitize manufacturer curves? Tools like WebPlotDigitizer can extract curve data from published graphs. Kodak and Fuji publish these for most current stocks.
- **Curve fitting**: What functional form best fits these curves? Polynomial? Spline? A sum of exponentials (common in sensitometry literature)? What's the best parameterization for fast evaluation?
- **Channel crosstalk**: The dye layers are not perfectly spectrally separated — magenta dye absorbs some cyan light, etc. Is a 3x3 or 4x5 matrix correction sufficient? This is essentially the same problem as camera sensor metamerism correction.
- **Inverting the forward model**: If we have `density = f(log_exposure)` per channel (the forward model), we need the inverse `log_exposure = g(density)`. If f is monotonic, this is a lookup table or a polynomial inverse. Any edge cases (low density toe, high density shoulder)?

Key sources: Kodak E-4051 (Ektar), Kodak E-4046 (Portra 160), Kodak E-4050 (Portra 400), Fuji datasheets for Pro 400H, Superia, Velvia.

### 4. From Density to Display-Referred Color

Inverting the negative gives us scene-linear values (estimated scene exposure per channel). We then need to map these to a display-referred colorspace for the user.

- **White point / gray world**: How to set the exposure baseline? Average frame? User-selected gray card? The film rebate (base + fog density)? This is essentially an auto-exposure / auto-white-balance problem but with film-specific constraints.
- **Tone mapping**: Scene-linear values have huge dynamic range. How much tone mapping is appropriate? A simple gamma curve? A filmic tone curve (e.g., ACES, AgX, Reinhard)? Should the tone curve be film-stock-specific?
- **Saturation / color matrix**: The dyes in C-41 film are not the same primaries as sRGB/Display P3. A 3x3 color matrix (or a 3D LUT) can map from film dye space to display space. Can we derive this matrix per-stock from the reference scan library? This is a linear least-squares fit given matching pairs.

### 5. Using the Reference Scan Library for Calibration

The reference library is our calibration asset. Approach:

- **Per-stock parameter fitting**: For each film stock, we have (negative, target-positive) pairs. We can fit the parameters of a deterministic pipeline to minimize error between pipeline output and target. Parameters might include: mask color, per-channel contrast curves, color matrix, tone curve shape.
- **3D LUT generation**: Fit a 3D LUT per stock that maps RGB_in_negative → RGB_out_positive. This is essentially a lookup table sampled on a 33x33x33 grid, interpolated at runtime. Generates clean code, very fast at runtime, and captures nonlinear color relationships without needing to understand them. The downside: LUTs don't generalize past their training gamut (extreme exposures). But for well-exposed negatives, they work.
- **Validation methodology**: Hold out some frames per stock. How do we measure "good"? Delta-E against the target? Subjective preference? How close is close enough?

### 6. Existing Open-Source Work to Study

These projects have already solved pieces of this problem. Read their source code:

- **darktable negadoctor** (`src/iop/negadoctor.c`): Per-channel black point from rebate, automatic mask detection, D-log E curve approximation.
- **RawTherapee Film Negative tool** (`rtengine/filmnegativeproc.cc`): Per-channel power-law model adopted as Phase 1 implementation. Parameters (redRatio, greenExp, blueRatio) and auto-calibration via medians implemented in Swift with CPU/GPU/Metal parity. Upcoming phases target base density + color space conversion and flat-field calibration.
- **filmulator** (`github.com/CarVac/filmulator-gui`): Approaches the problem from the other direction — simulates film development from a digital image. The forward model might be invertible.
- **Grain2Pixel** (Photoshop plugin, closed source but worth studying the output/methodology): Reportedly uses a large database of per-stock calibration shots.
- **Negative Lab Pro** (Lightroom plugin, closed source): The most popular commercial tool. Any technical blog posts, interviews with the developer, or reverse-engineering writeups?
- **ColorPerfect** (Photoshop plugin): One of the oldest commercial tools. Uses per-stock "ColorPos" profiles. What are those profiles? Can they be reverse-engineered or replicated?

### 7. Implementation Approach in Swift

Assuming we settle on a pipeline, how to implement it efficiently in Swift:

- **vImage / Accelerate**: Apple's SIMD image processing framework. Gives us per-channel operations, histogram operations, LUT application, and color conversion all on the GPU via Metal, transparently. Much faster than pixel-by-pixel loops.
- **Metal shaders**: If vImage doesn't cover everything (e.g., complex per-stock curves, 3D LUT interpolation), write Metal compute shaders for the hot path.
- **LUT format**: 3D LUTs as `.cube` files (industry standard, simple text format, trivially readable in Swift) or a compact binary format.
- **Parameter storage**: Per-stock calibration data as a simple JSON/Plist file or compiled into the binary. A few kilobytes per stock.

## Specific Technical Questions to Answer

Beyond the broad survey, we need concrete answers to these:

1. What is the correct mathematical operation for orange mask compensation? Is it additive (scanner_RGB - mask_RGB), multiplicative (scanner_RGB / mask_RGB), or something dependent on density?
2. Can D-log E curves be adequately approximated by simple functions (4th-order polynomial, gamma + offset) or do we need spline interpolation from digitized datasheet points?
3. What is the channel crosstalk matrix for typical C-41 films, and can we compute it from the reference library by linear regression on known positives?
4. For the "noisy" parts of the image (deep shadows in the negative = highlights in the positive, where the negative is thin), is there a principled way to avoid amplifying scanner noise?
5. What does the "rebate method" (darktable) actually do step by step, and what are its failure modes?
6. Can we produce better results than darktable's negadoctor, and if so, where specifically would the improvements come from?

## Suggested Deliverables

1. A survey of existing approaches with mathematical detail — equations, not just descriptions.
2. A recommended pipeline with a clear block diagram and the specific math at each stage.
3. Parameters that need per-stock calibration, and the method to fit them from the reference library.
4. Pseudocode or skeleton Swift for the core inversion pipeline.
5. References: papers, datasheets, source files, and specific line numbers in open-source projects.
