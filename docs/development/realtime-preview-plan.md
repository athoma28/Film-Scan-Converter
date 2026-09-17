# Still Preview Architecture

The current renderer uses bounded image sources, Core Image/Metal correction,
and one native viewport shared by the image and overlays. See
[development status](native-macos.md) for verification and the
[roadmap](../improvements/MacOS-Native-Roadmap.md) for remaining work.

## Sources And Ownership

| Source | Contract |
|---|---|
| Standard image | ImageIO preview bounded to 1000px. |
| RAW draft | Requested 640px CFA-preserving shrink followed by colour-accurate demosaic. |
| RAW inspect | Requested 4000px selected-file preview. |
| RAW lookahead | Requested 3200px for up to three unseen neighbours. |
| RAW full preview | Selected-file full-sensor 1-pass decode; demoted on selection change. |
| RAW continuous edit | A 2048px raster retained with the selected full preview; used only during supported point-control gestures. |
| Classification | Separate 256px analysis source. |
| RAW export | Independent final-quality three-pass camera-scan decode; one selected-file result may be retained for settings-only re-export. |

Requested bounds are not exact dimensions; see [mosaic binning](xtrans-preview-mosaic-binning.md).
Selecting a cached lookahead preview skips inspect and upgrades to full detail.
**Load RAW Preview** skips ahead to the same full-preview decode. Embedded JPEGs
supply sidebar thumbnails and repeated-capture detection, with a canvas warning
if RAW colour is unavailable.

Preview sessions use LRU eviction, a persisted count limit (default eight), and
a 256 MiB byte bound. The current UI has no cache-size selector. Sidebar
thumbnails have separate count/byte limits. Lookahead does not decode another
full-resolution RAW. Draft, inspect, full preview, neighbour lookahead, stack members, and RAW export
share a priority scheduler. Selected work preempts speculative neighbours; edits
pause preview upgrades/lookahead until gesture release. Cancellation propagates
to LibRaw progress callbacks and custom Fuji strip, CFA shrink, and X-Trans
wavefront boundaries. Selection changes drop retained export pixels. Navigation
reuses the selected full preview's earlier smaller tier instead of resizing on
the main actor. That fallback counts against the bounded background cache.

## Rendering

`StillPreviewRenderer` applies inversion, tone/color, white balance, curves,
wheels, orientation, supported manual crops, and display conversion. Swift CPU
processing is the reference/export authority and fallback for geometry and measured-density paths
that are not integrated with GPU correction.

Render requests carry immutable settings and generation state. One request may
be active; only the latest pending values are retained. Completed point edits
publish in revision order during a drag, while old source, selection, geometry,
and comparison generations cannot publish. On a selected full-sensor RAW,
supported continuous point edits use the 2048px GPU raster while preserving the
full logical document size. Gesture release corrects the full source with current
settings: Fit scales the corrected graph to backing pixels, while inspection
renders the visible source region over a small overview. Unsupported CPU paths
keep full-source correction and never use the interaction proxy. A selected-source
CPU cache reuses unchanged geometry and Darkroom analysis. Color/tone linear
scratch is bounded by row bands, preserving full-source analysis and arithmetic.
Monotonic latency/gap metrics and the `Frame Published` signpost measure publication,
not screen presentation. ImageIO calls remain synchronous. See the
[work-reuse follow-up](../performance/viewport-and-work-reuse-2026-09-16.md) and
[earlier proxy measurement](../performance/preview-scale-2026-09-14.md).

Darkroom's CPU analysis supplies both CPU rendering and GPU uniforms. Sorted
sample channels are reused across percentile queries. Each immutable renderer
also reuses one analysis keyed by resolved profile and paper values. CPU clipping
diagnostics sample up to 65,536 pixels without converting the full frame to Double.
Statistics follow publication asynchronously, with one active and one latest
pending sample. Gestures submit at most ten diagnostic updates per second; release
refreshes the final revision. Old-source or old-frame statistics cannot overwrite
the latest frame's diagnostics.
Preview requests retain only an existing compatible flat-field buffer; unity
allocation/resizing is deferred to CPU density rendering, so ordinary GPU
slider events do not allocate a full-image calibration field on the main actor.

Settings persistence coalesces per-file deltas and encodes/writes on a serial
background owner. Cache accounting includes renderer RGBA16 source backing and
the continuous-edit proxy. The selected full-resolution session remains exempt
from the bounded background byte total.
See the [performance implementation](../performance/implementation-2026-09-13.md)
for dispatch/fallback rules, durability, lookup processing, and validation.

## Viewport And Geometry

`NSScrollView` supplies momentum pan and cursor-centered pinch. Fit, step zoom,
and 100% commands act on current-preview pixels. Comparison and resolution
upgrades preserve the viewed region; selection changes reset to Fit.

Image, dust, crop, straighten, and perspective share a viewport transform.
Overlay gestures arrive in viewport points and are converted to document pixels
using the native magnification. Source-geometry editors reveal the oriented
scan; manual-crop editing reveals the post-straighten canvas. Clearing manual
crop retains earlier geometry. Changing that geometry invalidates the dependent
crop and stale diagnostic overlays.

Full-resolution stacks retain original sample statistics and HDR weights by
merging temporary original-capture storage in row bands. A failed sharper tier
retains a usable prior result and reports the failure.

## Verification

The [test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md) covers native viewport transitions,
comparison, crop gestures, roll behavior, and independent-reader output checks.
The standalone comparator enforces the 2/255 CPU/GPU channel tolerance and
fails if Metal or completed comparisons are missing.

Re-measure the [renderer and app-path benchmarks](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/README.md)
when source sizes, scheduling, kernels, geometry, or cache ownership change.
[Analysis benchmarks](../performance/preview-analysis.md) isolate diagnostics
and Darkroom work. Their timings do not establish whole-app slider latency.
