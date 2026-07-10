# Swift Port Evaluation

**Status:** Historical architecture review, superseded by the native status page

This document records the main conclusions from the June 2026 Swift-port
evaluation. It is not a roadmap or implementation checklist. For current
capabilities and limitations, use
[Native macOS Development Status](native-macos.md). For ordered work, use the
[Native macOS Product Roadmap](../improvements/MacOS-Native-Roadmap.md).

## Conclusions That Still Apply

- Keep LibRaw behind a narrow C bridge and return owned 16-bit BGR buffers to
  Swift.
- Keep preview and export on the same authoritative processing contract. The
  bounded Core Image renderer may accelerate interaction, but CPU processing
  remains the export reference.
- Use exact frozen fixtures where deterministic Python/OpenCV equivalence is a
  product requirement. Use documented tolerances only for genuinely different
  decoder or interpolation implementations.
- Keep large RAW batches memory bounded: decode, classify, process, and write
  one unloaded file at a time.
- Treat app wiring as part of completion. A standalone engine type or passing
  unit test does not make a feature available to users.

## Superseded Assumptions

The original evaluation predated substantial implementation work. These items
are now complete and should not be planned from this document:

- pure-Swift contour detection and minimum-area crop geometry;
- perspective-corrected preview and export;
- TIFF, JPEG, PNG, and processed-RGB DNG export;
- memory-bounded lazy Export All;
- bounded latest-value-wins still preview rendering;
- automatic film-kind classification and rebate selection;
- density-pipeline preview/export integration and profile separation;
- semantic photographic adjustments, curves, and color wheels;
- per-file persistence, named presets, and correction copy/paste.

The standalone histogram-equalisation prototype, linear-capture diagnostics
prototype, and unused density-display GPU prototype were removed because they
had no live app path. If those capabilities return, they should land through a
shared preview/export entry point with workflow-level tests.

## Current Boundary

Dust-mask detection exists, but Telea inpainting and applied dust removal do
not. Self-contained app/ZIP packaging is complete; Developer ID notarization,
Gatekeeper/clean-machine validation, broader packaged-app corpus evidence, and
essential editing-workflow work remain. The authoritative status page owns any
changes to that boundary.
