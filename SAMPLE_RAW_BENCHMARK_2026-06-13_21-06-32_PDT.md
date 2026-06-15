# Representative RAF Benchmark

Date: 2026-06-13 21:06:32 PDT  
Branch: `dev`

## Corpus

| File | Classification | Correct rotation | Scene |
| --- | --- | ---: | --- |
| DSCF0669.RAF | Black-and-white negative | 3 | Night exterior |
| DSCF0718.RAF | Color negative | 1 | Outdoor daylight |
| DSCF0729.RAF | Color negative | 1 | Mixed indoor lighting |
| DSCF2417.RAF | Black-and-white negative | 0 | Daylight portrait |
| DSCF2422.RAF | Color negative | 3 | Indoor portrait |

All files are Fujifilm X-T5 RAFs. Four of five film frames require rotation independent of the camera EXIF orientation.

## Method

- Decoded RAFs using Film Scan Converter's RawPy settings.
- Evaluated neutral, manual-base, tuned tonal/color, alternate-temperature, contrast, recovery, and dust-removal edits.
- Searched 320 constrained color-edit candidates per color negative on the proxy path.
- Ranked candidates using central-image clipping, tonal percentiles, contrast, entropy, and channel balance, followed by visual inspection.
- Benchmarked selected edits at 10 MP half-resolution decode and representative 40 MP full-resolution decode.
- Compared optimized output against the original `main` pipeline.

The repeatable runners are:

- `tests/decode_sample_raw.py`
- `tests/benchmark_sample_raw.py`

## Selected Edits

### DSCF0669

Selected `tonal_recovery`:

- White point: -12
- Gamma: 12
- Shadows: 25
- Highlights: -35

This lifts the dark market aisle while retaining the string lights. The contrast preset is punchier but clips more shadow detail.

### DSCF0718

Selected `tuned_cooler`:

- Base RGB: (163, 111, 67)
- Black point: 15
- White point: 10
- Gamma: -5
- Highlights: -20
- Tint: 0
- Temperature: 0

Compared with auto conversion, entropy rises from 6.69 to 7.67 bits and the median RGB values become substantially more balanced.

### DSCF0729

Selected `tuned`:

- Base RGB: (169, 117, 74)
- Black point: 5
- White point: 10
- Gamma: 20
- Shadows: 30
- Highlights: -20
- Tint: -5

This handles the mixed indoor lighting without the washed-out blue auto conversion. Entropy rises from 6.68 to 7.80 bits.

### DSCF2417

Selected `contrast`:

- Black point: -12
- White point: 5
- Gamma: 2
- Shadows: -12
- Highlights: 8

The neutral conversion is already strong. The contrast version increases separation in the grass and clothing while retaining low clipping.

### DSCF2422

Selected `tuned`:

- Base RGB: (197, 150, 111)
- Black point: 10
- White point: -10
- Gamma: 20
- Shadows: 30
- Highlights: 10
- Temperature: 10
- Tint: -10

This removes the washed-out blue auto conversion and retains the indoor warmth. Entropy rises from 6.72 to 7.67 bits.

## 10 MP Performance

Best processing times from three runs:

| File / edit | Cold | Warm cached |
| --- | ---: | ---: |
| DSCF0669 neutral | 0.097 s | 0.038 s |
| DSCF0669 tonal recovery | 0.219 s | 0.162 s |
| DSCF0718 neutral auto | 0.549 s | 0.176 s |
| DSCF0718 tuned cooler | 0.730 s | 0.477 s |
| DSCF0729 neutral auto | 0.511 s | 0.176 s |
| DSCF0729 tuned | 0.796 s | 0.597 s |
| DSCF2417 neutral | 0.100 s | 0.040 s |
| DSCF2417 contrast | 0.227 s | 0.166 s |
| DSCF2422 neutral auto | 0.495 s | 0.177 s |
| DSCF2422 tuned | 0.807 s | 0.592 s |

Across all 23 edits:

- Cold total: 11.77 seconds.
- Warm cached total: 7.17 seconds.
- Warm processing uses approximately 61% of cold processing time.
- Median cold edit: 0.495 seconds.
- Median warm edit: 0.177 seconds.

## 40 MP Export-Scale Performance

Full-resolution RawPy decoding took approximately 8.16-8.19 seconds per RAF.

| File / edit | Original `main` | Optimized `dev` | Speedup | Exact pixels |
| --- | ---: | ---: | ---: | --- |
| DSCF2417 neutral | 1.848 s | 0.471 s | 3.93x | Yes |
| DSCF2417 contrast | 1.764 s | 0.972 s | 1.81x | Yes |
| DSCF0729 neutral auto | 6.271 s | 2.034 s | 3.08x | Yes |
| DSCF0729 tuned | 5.253 s | 3.422 s | 1.53x | Yes |

## Quality Findings

- Manual film-base settings are essential for these color negatives. The default auto path is consistently washed out and blue/cyan.
- Tuned color edits raise tonal entropy by roughly 0.95-1.12 bits while maintaining low highlight clipping.
- Black-and-white neutral conversion is already effective; tonal controls mainly provide stylistic choices.
- Dust detection adds roughly 0.08-0.11 seconds to cold 10 MP processing.
- Dust inpainting adds roughly 0.08-0.10 seconds to color preview rendering and approximately 0.02-0.03 seconds to black-and-white rendering.
- Existing dust removal has limited visual benefit on the visible long hairs and larger debris in this corpus.
- Automatic crop identifies the film strip rather than consistently isolating the image frame in these representative scans.

## Optimization Added During This Benchmark

The representative tuned edits exposed slow masked-array arithmetic in adjusted exposure processing. It was replaced with NumPy operations that reproduce the original promotion and rounding behavior.

- Full 23-edit cold benchmark improved from 13.84 to 11.77 seconds.
- Full 23-edit warm benchmark improved from 9.28 to 7.17 seconds.
- Reference output pixels remain exact.
