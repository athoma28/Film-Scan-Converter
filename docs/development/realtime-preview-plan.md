# Real-Time Still Preview Outcome

**Status:** The original equivalence and latency gates through Stage 3 are
complete. The proposed idle full-resolution replacement was retired when
browsing moved to a preview-only contract.

**Last verified:** 2026-07-17

This page records the design outcome of the real-time preview work. It is not
the active roadmap. Current product priority belongs in the
[Native macOS Product Roadmap](../improvements/MacOS-Native-Roadmap.md), current
evidence belongs in [Native macOS Development Status](native-macos.md), and
app-path latency measurements belong in
[40 MP Export Performance](../performance/40mp-export.md).

## Shipped Contract

- RAW browsing extracts the camera's embedded preview directly to a bounded
  1000px 16-bit display source. Standard images use an ImageIO thumbnail at the
  same bound.
- A separate 256px source drives classification and median calibration.
- Browsing keeps that bounded source. It does not start a speculative
  full-resolution RAW decode or later replace the displayed image.
- Lookahead prepares preview sessions only and is bounded by both the selected
  2/4/8/16/32-file limit and a 256 MiB byte limit.
- Export independently decodes camera RAW at full resolution with the
  `rawTherapeeCameraScan` profile and recalibrates power-law film-base medians
  from the export pixels.
- The Core Image/Metal correction renderer is the normal interactive path on
  supported MacBook Pro hardware. The Swift CPU pipeline remains the
  deterministic reference, export authority, CI/headless path, and fallback.
- Scheduling is latest-value-wins: one render may be active and only the newest
  pending parameter snapshot is retained.
- The still image, dust mask, and crop/straighten/perspective editors share one
  native scroll viewport. It provides momentum pan, trackpad pinch, Fit,
  step-zoom, and 100% preview-pixel commands.
- Original/corrected comparison retains the viewport and magnification. An
  on-canvas badge identifies the bounded preview source and displayed pixel
  dimensions.

## Completed Interactive Work

1. **State flow and instrumentation.** Slider bindings read live model values,
   render requests carry immutable parameter snapshots, and `AppModel` exposes
   submitted, displayed, and dropped render counters plus signposts.
2. **GPU correction renderer.** `StillPreviewRenderer` implements film-mode
   inversion, protected tone and color controls, white balance, curves, color
   wheels, orientation, and display conversion on the Core Image/Metal path.
3. **Visual equivalence.** Current production CPU/GPU grids cover 2,725 channel
   comparisons with zero failures and a maximum difference of 2/255.
4. **Latency gate.** The deterministic adjustment-heavy 1080×720 release
   benchmark now exercises dye crossover as well as protected color/tone,
   curves, and color wheels. The 2026-07-15 M4 Pro run with crossover active
   measured 1.7717 ms median and 2.3590 ms p95 across 120 renders. Before dye
   crossover joined the workload, four recorded post-change runs measured
   2.9641–3.0286 ms p95; the pre-optimization p95 was 3.9959 ms.
5. **App-path baseline.** Release measurements now cover first corrected paint,
   cached and uncached switching, rapid-selection drain, logical preview-cache
   bytes, and Mach physical footprint. Cache-depth sampling at 2, 8, and 32 is
   complete for the local six-RAF corpus.
6. **Photographic viewport.** A native `NSScrollView` surface supplies normal
   Mac scrolling, momentum, rubber-banding, and cursor-centered pinch zoom.
   Menu and toolbar commands provide Fit, zoom-in/out, and 100%, while image and
   editing overlays retain a common transform.

These are bounded local regression measurements, not universal hardware
claims. The three-repetition app-path p95 values are the slowest samples rather
than population-tail estimates.

## Retired Stage 4

The original plan proposed an idle full-resolution CPU render that would
replace the interactive preview after a gesture ended. That is no longer part
of the product contract:

- it would make browsing start authoritative RAW work that export already owns;
- it would increase large-file latency and memory pressure;
- it would turn preview color differences from embedded camera rendering into a
  delayed visual jump rather than a clear preview/export boundary.

CPU/GPU equivalence remains a test and diagnostic contract, not a requirement
to swap a second image into the browsing canvas. A direct Metal-backed display
surface or deeper render-stage instrumentation remains a candidate only if
profiling exposes a user-visible display-path bottleneck.

## Remaining Verification

- Add a dedicated late-render regression proving a previous file cannot publish
  after selection changes; generation guards and cancellation already enforce
  the behavior in the app path.
- Add a UI automation smoke test that drags each adjustment and confirms visible
  updates when reliable macOS app automation is available.
- Re-run the deterministic renderer and app-path benchmarks after changes to
  preview source size, scheduling, kernels, geometry integration, or cache
  ownership.

The app-path sequential-export/cancellation and post-run-memory measurement is
complete, so there is no open-ended broader performance cycle. Direct
representative-image judgment and future UI-automation evidence are tracked by
the roadmap and native status rather than by this historical outcome document.

## Durable Rules

- Keep the 1000px display source and 256px analysis source explicit.
- Never prefetch full-resolution RAW buffers for browsing or lookahead.
- Keep only the newest pending render snapshot.
- Preserve the CPU processing path as the deterministic pixel authority.
- Keep display transforms outside the authoritative processing result.
- Keep image and diagnostic/editing overlays in one viewport transform, and do
  not reset that viewport when Original comparison changes the displayed pixels.
- Keep 100% explicitly defined against bounded preview pixels, and keep the
  preview-source badge visible so it is not confused with full-resolution
  export evidence.
- Treat color-management, EDR, and display-profile differences as measured
  preview concerns rather than silently baking them into export pixels.
- Do not revive an authoritative browsing replacement without new evidence and
  an explicit memory, latency, and visual-transition contract.
