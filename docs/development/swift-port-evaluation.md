# Native Architecture Contracts

The native application is implemented. Use [development status](native-macos.md)
and the [roadmap](../improvements/MacOS-Native-Roadmap.md) for current scope.
This page retains only the architecture constraints that remain relevant:

- Keep LibRaw behind a narrow C/C++ bridge returning Swift-owned 16-bit BGR.
- Keep preview and export adjustment/geometry semantics aligned while preserving
  their separate source-resolution and demosaic-quality contracts.
- Use deterministic Swift CPU results as the native processing authority, with
  frozen Python/OpenCV fixtures only for explicitly shared behavior.
- Bound preview caching, sequential RAW export, and original-sample stacking.
- Verify real app wiring and recoverable errors as well as engine behavior.

See [preview architecture](realtime-preview-plan.md),
[native package contracts](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/README.md), and [tests](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md).
