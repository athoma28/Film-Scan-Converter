# Native Code Health Reference

Current product priority belongs in the
[roadmap](docs/improvements/MacOS-Native-Roadmap.md), and verification belongs in
[development status](docs/development/native-macos.md). Resolved audit findings
are not active implementation tasks.

Maintain the contracts established by the native cleanup work:

- shared coordinate/color math and safe mutable-buffer ownership;
- deterministic pixel equivalence for parallel processing and histogram medians;
- exclusive editing overlays with meaningful accessibility and visible failures;
- cleanup of failed exports and recoverable malformed-media handling;
- strict Swift formatting and macOS 14/15 regression/build coverage.

Large app/model files can be split when a concrete feature boundary makes review
safer. Architectural size alone is not a measured runtime defect. Additional
failure-injection seams, redistributable RAW fixtures, and controlled benchmark
infrastructure should be scoped from a present validation need, not inherited
as numbered obligations from an old audit.

The [correctness contract reference](CODE-HEALTH-AUDIT-2026-09-02.md) records
B&W, stacking, crop, and diagnostic invariants. Git history retains the original
review detail.
