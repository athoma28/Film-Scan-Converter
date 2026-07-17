# Film Scan Converter

Welcome to the documentation for the Film Scan Converter!

The native Swift/macOS application is the primary product direction and the only
target for new features. Start with
[Native macOS Development Status](development/native-macos.md) for implemented
scope, evidence, limitations, and release position. The
[Native macOS Product Roadmap](improvements/MacOS-Native-Roadmap.md) is the
single ordered plan. It prioritizes fast image judgment, reversible editing,
roll consistency, and trustworthy output; stock-look learning is explicitly
parked until the project owner chooses to resume it.

The Python/Tkinter application is retained as a maintenance-only legacy
workflow because dust removal remains Python-only and fixture tools still use
legacy modules. Python retirement is not itself a blocker for the first native
release. Native automatic frame detection, manual crop/perspective correction,
self-contained app/ZIP assembly, and TIFF, JPEG, PNG, and processed-RGB DNG
export are implemented. The legacy
installation and usage guides remain available for users who need dust removal
or the historical all-in-one workflow. See
[Legacy Python Application](legacy-python.md) for the retirement policy.
