# Legacy Python Application

The Python/Tkinter application is now a **maintenance-only legacy
implementation**. It remains in `source/` because it still provides dust
handling, the historical all-in-one workflow, and fixture-generation utilities
that the native replacement has not retired.

All new product features and new processing functionality belong in the native
Swift/macOS project. Python changes should be limited to:

- critical correctness, data-loss, and compatibility fixes;
- keeping the frozen reference-fixture generators reproducible;
- preserving the existing cross-platform workflow until the native replacement
  reaches the retirement gates below.

The Python implementation is no longer the design authority for new features.
For shared legacy behavior, committed fixtures preserve compatibility. For new
Swift-only behavior, the authoritative contract is the deterministic
`FilmScanEngine` CPU implementation plus regression fixtures.

## Why It Is Not Archived Yet

Moving `source/` into an archive folder now would break or obscure active
workflows:

- native export of TIFF, JPEG, PNG, and DNG is now implemented;
- contour detection, automatic crop-box computation, perspective warp, and
  dust-mask detection are implemented natively; Telea inpainting and the app
  dust-removal workflow are not;
- the Python application remains the only workflow that includes automatic dust
  handling in the same batch-processing surface;
- Python/RawPy tools still generate or audit frozen compatibility fixtures and
  decode benchmarks.

## Retirement Gates

The Python application can move to `archive/python/` only after all of these are
true:

1. ~~Native individual and memory-bounded batch export pass round-trip,
   cancellation, partial-file cleanup, metadata, orientation, and collision
   tests.~~ Done. ExportManager + ExportFormat + UInt16Image.write with 19 tests.
2. ~~Native contour detection, crop-box computation, and perspective warp meet
   their documented compatibility or replacement contracts.~~ Done. Native
   dust handling remains.
3. A representative RAW corpus completes import, correction, and export through
   the native application with verified output.
4. Native packaging and release installation are documented and tested.
5. Frozen reference fixtures no longer require importing production modules from
   `source/`, or the required fixture tooling is moved with stable paths.
6. The Python release and ART integration are explicitly marked unsupported or
   replaced.

Until then, keep `source/`, the Python regression workflow, and legacy user
documentation intact, but do not expand the Python product surface.

## Legacy Commands

Run the maintained Python regression suite:

```sh
.venv/bin/python -m unittest discover -s tests -p 'test_*.py'
```

Generate compatibility fixtures only when intentionally changing a shared
legacy behavior:

```sh
.venv/bin/python tests/generate_native_snapshots.py
.venv/bin/python tests/generate_raw_decode_reference.py
```

See [Native macOS Development](development/native-macos.md) for the active
product direction and current work.
