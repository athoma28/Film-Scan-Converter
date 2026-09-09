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
full-resolution RAW. Preview/detail and export decode work serialize; export
cancels speculative lookahead. Selection changes drop retained export pixels.

## Rendering

`StillPreviewRenderer` applies inversion, tone/color, white balance, curves,
wheels, orientation, and display conversion. Swift CPU processing is the
reference/export authority and fallback for geometry and measured-density paths
that are not integrated with GPU correction.

Render requests carry immutable settings and generation state. One request may
be active; only the latest pending values are retained, and obsolete results
must not publish. Signposts and submitted/displayed/dropped counters provide
observability. Cancellation checks surround synchronous work rather than
interrupting a LibRaw or ImageIO call in progress.

Darkroom's CPU analysis supplies both CPU rendering and GPU uniforms. Sorted
sample channels are reused across percentile queries. CPU clipping diagnostics
sample up to 65,536 pixels without converting the full frame to Double.

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
