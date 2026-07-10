# Legacy Python Application

The Python/Tkinter application is maintenance-only. All new product features,
processing behavior, and UI work belong in the native Swift/macOS application.

Python changes are limited to:

- critical correctness, data-loss, and compatibility fixes;
- reproducibility of frozen reference fixtures and decode benchmarks;
- preservation of the existing cross-platform workflow while it remains
  supported.

The Python implementation is a compatibility source for shared historical
behavior, not the design authority for new native features.

## Current Role

Keep `source/` available because:

- it remains the only complete workflow with automatic dust detection and
  inpainting;
- fixture and benchmark tools still import production Python modules;
- legacy cross-platform releases and ART integration remain documented.

Native TIFF/JPEG/PNG/processed-RGB-DNG export, crop detection, perspective
correction, and dust-candidate detection are implemented. Native dust removal
is not.

## Retirement Policy

Python retirement is repository cleanup, not a blocker for the first sound
native release. The native app may ship while dust removal remains explicitly
legacy-only.

Archive or remove the Python product only when all of the following are true:

1. a representative corpus has completed import, correction, and all-format
   export through the packaged native application with verified output;
2. a signed/notarized native artifact has passed Gatekeeper and clean-machine
   installation;
3. any Python-only workflow that will remain supported—currently dust removal
   and cross-platform/ART use—has been replaced or explicitly discontinued;
4. frozen fixture and benchmark tools no longer require production modules in
   `source/`, or those tools move with stable paths;
5. public installation, usage, release, and ART documentation clearly states
   the final support boundary.

Do not port a feature solely to satisfy retirement. Prioritize native user
value, correctness, and release evidence through the
[product roadmap](improvements/MacOS-Native-Roadmap.md).

## Legacy Commands

Run the maintained Python regression suite:

```sh
.venv/bin/python -m unittest discover -s tests -p 'test_*.py'
```

Regenerate compatibility fixtures only for an intentional shared-behavior
change:

```sh
.venv/bin/python tests/generate_native_snapshots.py
.venv/bin/python tests/generate_raw_decode_reference.py
```

See [Native macOS Development Status](development/native-macos.md) for current
native evidence and limitations.
