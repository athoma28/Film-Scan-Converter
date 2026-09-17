# Performance research implementation

This implements the measured editing bottlenecks and bounded optimizations from
the [second research pass](research-pass-two-2026-09-13.md) and
[performance research directions](research-directions-2026-09-12.md).

## Settings saves

The main actor updates settings in memory and submits one per-path delta to a
serial background persistence owner. The owner retains its own dictionary and
performs both JSON encoding and atomic file replacement off the event handler.
The pending mailbox retains the newest revision per path, including removals
and resets. It does not queue a complete encoding for every slider tick.

Keyboard/text changes debounce for 300 ms. Continuous edits request a save at
least every two seconds; gesture completion and selection changes request an
immediate save. Orderly application termination waits for all submitted edits
and cancels termination if saving fails. The existing JSON format remains
readable, and failures remain visible in the app.

The [persistence design note](settings-persistence-implementation.md) details
ordering, retry behavior, and the event-handler measurement.

An abrupt process exit can lose changes since the last successful write:
normally the debounce or two-second interval plus write time. Slow or failed
storage can extend that window. Completing a gesture requests asynchronous
durability; it does not block the UI until the disk write completes.

## Natural B&W CPU processing

Natural B&W images of at least one million pixels use an exact integer-gray
lookup after geometry. The ordinary CPU path remains the oracle and handles
small images and incompatible conversion modes. The compiler shares the
production point-adjustment implementation, retaining intermediate UInt16
rounding, three output channels, and the original-channel zero-light mask.

Two cached inversion tables depend on the monochrome profile, green median,
and pre-inversion exposure. Four cached tone tables depend on active semantic
or legacy tone controls and the master curve. Both caches are bounded and
serialize construction. Composing them needs a temporary 384 KiB table.
The semantic-tone path therefore avoids expanding the whole image into three
Double channels; geometry and final output retain their existing storage needs.

This preserves the current Standard and Shanghai GP3 profile output, including
the Standard profile's documented flat interval. It is a performance change,
not a photographic curve replacement.

## Preview responsiveness and retained memory

The renderer reuses one Darkroom analysis for an immutable source and resolved
profile/paper values. Exposure, white balance, and wheel changes reuse it;
profile/paper changes and a new source invalidate it.

Manually cropped corrections can remain on the GPU, using the CPU's outward
crop rounding after quarter turns and horizontal flip. Automatic crop,
perspective, straighten, and measured-density processing still use the CPU.
Manually cropped Original/crop-only views preserve exact CPU packing. Cropped
Darkroom and power-law conversions without measured medians also use the CPU
because their analysis depends on the cropped source.

Completed point edits publish in increasing revision order even if a newer edit
is waiting. A selection, source, geometry, conversion-mode, or Original change
invalidates earlier frames. The final queued edit still requires exact current
parameters. The queue retains one active and one pending request and no longer
adds an eight-millisecond pause after an active render.

Render metrics use a monotonic clock. Control setters capture their start before
persistence/preparation; statistics record preparation, queue wait, render,
interaction-to-publication latency, and gaps between publications during active
editing. The signpost is named `Frame Published`: assigning an NSImage is not
proof of screen presentation. Display timing and direct Metal presentation
remain separate work.

The session cache now counts its retained RGBA16 backing as well as distinct
UInt16 source/analysis arrays, avoiding double-counting shared array storage.
The selected full-resolution source remains exempt from the bounded background
cache. Driver allocations and transient output surfaces are additional memory;
the accounting is not a measured process footprint.

## Validation

The release app builds successfully; all 20 changed Swift files pass strict
formatting checks. The final regression run reported **289 passing tests of
290**, in 37.196 seconds. All new persistence, lookup, cache, crop, and publication
tests passed, along with the shared correction and CPU/GPU regression checks.

The remaining failure is the existing RAW scenario reference: its recorded
LibRaw 0.21.4 output is 7752 × 5184, while the installed LibRaw 0.22.2 produces
7752 × 5178. The dimensions fail before correction and its five corrected hashes
also differ. Decoder/shim sources, the reference test, and fixture are unchanged
from the repository revision. The golden output was not regenerated.

The [September 14 compatibility repair](../development/raw-decode-compatibility.md)
subsequently identified both an active-area change and a new X-T5 camera matrix.
It restores the established decoder contract; the camera and correction
references now pass with their original hashes. This does not alter the
September 13 measurement record above.

Graphics tests require normal macOS graphics access. A restricted first run
could not produce GPU output even in existing baseline cases; rerunning those
18 tests with graphics access passed. The final 290-test run also had graphics
access. MkDocs is unavailable in the local Python environment; local links in
the implementation and updated architecture pages were checked directly.

### Bounded measurements

The [recorded samples](implementation-measurements-2026-09-13.json) include source
hashes, environment, and raw setter samples. These final-run timings are from
arm64 macOS 15.7.9 / Swift 6.1.2 with two build jobs and serial release tests.

| Workload | Observation |
|---|---|
| Retained 2048 × 1024 Natural B&W, semantic tone and master curve | Ordinary: 39.07 ms; cold lookup: 9.40 ms; three warm samples: 2.47 / 2.33 / 1.68 ms. Zero differing UInt16 components. |
| 640-entry history, 120 actual setters without decode/render | Mean 0.131 ms, maximum 0.194 ms. Final flush and relaunch verified. |
| 640-entry history, small decoded preview, 60 exposure edits at 8 ms intervals | All 60 frames published before release. Setter mean 0.592 ms, maximum 1.292 ms; longest active publication gap 13.43 ms; final interaction-to-publication latency 7.51 ms. GPU path and saved final settings verified. |

The LUT test avoids one 48 MiB full-frame Double buffer at this size, based on
array payload arithmetic; it does not measure process footprint. The ordinary
and cold timings have one sample each. These are bounded observations, not a
stable benchmark ranking, 40 MP speedup, or energy claim. The edit replay calls
real model setters but does not synthesize native mouse input or measure screen
presentation. The probes use synthetic settings and retained pixels; the broader
regression additionally exercises the local RAW reference described above and
sampled Phoenix classification/rendering checks.

Reproduce the implementation-specific checks and probes from the repository
root, with macOS graphics access:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/native/FilmScanEngine/.build/arm64-apple-macosx/release/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/native/FilmScanEngine/.build/arm64-apple-macosx/release/ModuleCache" \
RUN_NATURAL_BW_LOOKUP_BENCHMARK=1 RUN_EDIT_REPLAY_BENCHMARK=1 \
swift test --disable-sandbox -c release --package-path native/FilmScanEngine \
  --jobs 2 --no-parallel \
  --filter 'PerFileSettingsPersistenceTests|NaturalMonochromeLookupTests|StillPreviewPerformanceTests|PreviewPublicationTests'
```

## Remaining research

The reports also propose photographic curve changes, extended-range HDR storage,
noise-calibrated merge weighting, fractional registration, viewport-sized/direct
GPU presentation, and a Metal demosaic. Those require the separate quality and
measurement gates described in the reports. This implementation does not adopt
an uncalibrated curve or noise model, change the RAW decoder, or reinterpret
the positive linear-image contract as negative HDR radiance.

The subsequent
[full-resolution edit-scaling follow-up](preview-scale-2026-09-14.md) measures
source-sized gesture rendering and adds a bounded 2048px interaction raster with
an exact post-gesture refinement. It does not replace viewport-region rendering,
direct drawable presentation, or the photographic acceptance gates above.
