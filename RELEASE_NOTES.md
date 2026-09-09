# Release Notes

## Current Source — Unreleased

The development source targets macOS 14 or later and contains changes beyond
the published 0.2.0 Beta 1. This section describes source behavior; it does not
announce a new binary release.

- Develop, Geometry, Calibrate, and Export inspector pages with contextual
  conversion, tone/color, film-base, crop, and output controls.
- Colour-accurate staged RAW previews, parallel Fuji unpack and deterministic
  X-Trans wavefront demosaic, plus selected-file three-pass decode retention
  for settings-only re-export.
- Darkroom film/paper inversion, B&W tone curves with CPU/GPU parity, presets,
  roll-wide look transfer, and import-ordered navigation.
- Original-capture Noise/HDR stacking with bounded memory and temporary disk
  storage, explicit upgrade failures, and one output per enabled stack.
- Shared viewport/overlay coordinates, stable Original comparison and source
  upgrades, truthful full-output dimensions, and dependent manual-crop
  invalidation when upstream geometry changes.
- Bounded CPU preview statistics and faster Darkroom analysis. The latest
  isolated textured-input benchmark measured 103.34 → 43.83 ms p50; process
  peak increased 13.84 → 16.76 MB. Exact output references remain unchanged.

The September 8 native release run reported 580 tests: 570 passing records and
10 opt-in skips. Local packaged viewport/manual-crop and duplicate-stack
mechanics, and automated independent-reader export checks, are recorded in
[development status](docs/development/native-macos.md). Detailed timings and
source states are in the [analysis benchmark](docs/performance/preview-analysis.md).

Remaining validation includes broader photographic and real-roll/stack
judgment, Preview/Photos review on an independent Mac, and notarized distribution.
Native dust detection is diagnostic only. Processed DNG contains RGB output,
not untouched sensor RAW. See [Features](docs/features.md) for current limitations.

## Published Download

[Film Scan Converter 0.2.0 Beta 1](https://github.com/athoma28/Film-Scan-Converter/releases/tag/v0.2.0-beta.1)
was published August 14, 2026 for Apple Silicon Macs on macOS 14 or later.
It is ad-hoc signed and is not Apple-notarized. Its release page preserves the
artifact-specific feature list and verification; current-source claims above
must not be attributed to that ZIP.

Download the ZIP and matching SHA-256 file from the release page and follow
[Installation](docs/installation.md). New artifacts must identify their own
source commit, version/build, checksums, and validation under the
[release runbook](docs/development/native-release.md).
