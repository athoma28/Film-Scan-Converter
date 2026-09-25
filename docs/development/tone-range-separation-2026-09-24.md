# Separated tone ranges and grading levels — September 24, 2026

This change responds to the overlap between Highlights/Whites and
Shadows/Blacks in the native Develop inspector. It also adds three luminance
controls beneath the existing color wheels. The response is authored for Film
Scan Converter; the names and numeric values do not claim equivalence with
Camera Raw.

## Control contract

Photographic tone version 4 keeps the prior exposure, brightness, contrast,
shoulder, color and curve stages. The four basic range controls now have
different domains in encoded lightness:

| Control | Main response | Black/white output endpoints |
|---|---|---|
| Shadows | Broad dark range, tapering to zero by 0.72 | Both retained |
| Blacks | Deep tail below 0.28 | Both retained |
| Highlights | Broad bright range, starting at 0.28 | Both retained |
| Whites | Upper half above 0.50, concentrated toward white | Both retained |

The range bends are strictly monotone at public slider limits and join the
unaffected part of the scale smoothly. The bounds describe the response curve,
not fixed pixel masks on a particular photograph. A control can move a pixel
across another control's range when they are combined.

The three sliders in **Color Grading Wheels** have a deliberately different
role. **Shadow Floor** raises the actual black output point when positive, up
to 0.12 encoded at +1. **Midtone Level** bends the central 0.18–0.82 interval
while retaining its endpoints. **Highlight Ceiling** lowers the white output
point when negative, to 0.84 encoded at −1. Negative Floor and positive
Ceiling can push output beyond display black/white; later curves may still
compensate before final quantization. The controls work independently of wheel
hue and strength. The UI limits them to color-capable film because they are
presented with the grading wheels; the engine's tone path itself is shared.

All three controls default to zero and are saved inside
`PhotoAdjustmentParameters`. Named presets, clipboard corrections and per-file
settings carry them through the existing real app parser. Slider gestures use
the existing undo grouping. The Color & Balance and Tone & Light section markers
both reflect a grading-level adjustment.

## Saved edits and preferred looks

Version 1–3 parameters retain their existing rendering. Built-in looks are
pinned to version 2 so their initial appearance does not change when loaded.
New neutral edits use version 4. Moving Highlights, Shadows, Whites, Blacks, or
a grading-level slider on a version 2/3 edit promotes it to version 4 within the
same undo step. Version 1 keeps its explicit **Update Tone Controls** action;
the new grading-level sliders are disabled until that action is taken. Older
applications that understand at most version 3 cannot read saved version-4
adjustments.

The five user-preferred checkpoint recipes remain frozen in
`color-preference-checkpoints.json`. Their original settings and hashes were
not changed. The fresh-render result is recorded below.

## Verification

The reproducible photographic cohort uses the six archived 900px frames and
fixed region masks described in the
[ordinary slider response study](slider-response-study-2026-09-24.md).
The paired profile file is
`native/diagnostics/tone-response-separated-profiles.json`; it renders the
same 17 edits for versions 2 and 4, including basic ranges, grading levels and
combinations. The production Swift renderer writes each PNG and exact
parameter/correction document. The harness checks source/input provenance,
fresh preferred-look PNGs, and reports all regions and exclusions. This is a
control-response study, not a Camera Raw fit or unseen-film validation.

The completed CPU run is in
`dist/tone-response-separated-final-2026-09-25/`: 204 production PNG renders,
2,040 ordinary measurement rows, 1,020 paired version-2/version-4 measurement
rows, six frames and no frame exclusions. Its local `index.html` gallery,
`measurements.json`, `same-edit-comparisons.json` and `manifest.json` preserve
the images, numeric results and source/input hashes. All five fresh preferred
renders match their frozen PNG SHA-256 values exactly. The two paired profiles
use the same serialized controls except tone version; each response is measured
against its own baseline, since the baseline already contains nonzero
Highlights/Shadows and therefore differs across versions.

At ±0.25, the table gives the six-frame average change in encoded luma, in
8-bit levels, within each frame's **baseline** luminance fifth. These are
measurements of the finished images, not coefficients read from the curve:

| Version-4 edit | Darkest 20% | 20–40% | 40–60% | 60–80% | Brightest 20% |
|---|---:|---:|---:|---:|---:|
| Shadows +0.25 | +2.67 | +5.05 | +7.03 | +7.72 | +3.37 |
| Blacks +0.25 | +3.07 | +2.54 | +0.96 | +0.05 | 0.00 |
| Highlights −0.25 | −0.02 | −0.75 | −2.54 | −4.14 | −6.94 |
| Whites −0.25 | 0.00 | 0.00 | −0.22 | −1.29 | −4.03 |
| Shadow Floor +0.25 | +6.84 | +6.23 | +5.31 | +4.31 | +2.52 |
| Midtone Level +0.25 | +0.31 | +1.41 | +3.21 | +5.35 | +5.26 |
| Highlight Ceiling −0.25 | −1.02 | −1.82 | −3.01 | −4.34 | −6.79 |

The fixed bright **window** region in Phoenix DSCF3079 moves −7.79 with
Whites −0.25 versus −3.22 with Highlights −0.25; the Phoenix DSCF3091
**path** moves −7.11 versus −1.25. In the Pro Image DSCF5800 skin face,
leg and arm, Blacks +0.25 gives zero measurable change, while Whites −0.25
lowers them by −2.38, −1.67 and −6.57 respectively according to their
starting brightness. The shaded foliage in Fuji DSCF2892 moves +3.38 with
Blacks +0.25 versus +2.63 with Shadows +0.25; its sunlit foliage moves
+1.74 versus +5.21. Across the named skin and non-skin regions examined,
mean hue direction changes are under 0.04°, with brightness-linked chroma
changes and no change in the measured channel clipping percentages. These
fixed regions are samples, not exhaustive masks of each subject.

`PhotographicToneTests`, `GradingPointControlTests`,
`FocusedToneResponseTests` and `LookRecipeAppTests` pass 33/33 release tests,
including saved-parameter decoding, undoable promotion and parser round trips.
The standalone native comparator passes 4,608/4,608 cases: 4,164 GPU cases
within 2/255 of CPU, 444 explicit CPU routes, no failures; its new version-4
family contributes 30 GPU comparisons and 12 CPU routes. Python study tests
pass 19/19. Swift formatting lint and `git diff --check` pass.

The photographic study is CPU-only. The separately linked standalone study
binary fails on its first Metal image on this host, although the packaged
comparator runs Metal successfully. Thus the synthetic comparator does not
prove photographic Metal parity for these six frames. Full-resolution export,
unseen photographs and personal aesthetic acceptance remain unverified. An
earlier complete-suite attempt had one stale version expectation in
`LookRecipeAppTests`; that assertion was corrected and its focused group
passed. A subsequent headless complete-suite attempt lost graphics access, so
there is no green complete-suite claim for this final working tree.
