# Improvement Proposal Evaluation

> **Historical snapshot:** Evaluated on 2026-06-14 before native macOS
> implementation began. This file records the decisions from that audit and is
> not the current development plan. See
> [Native macOS Development](../development/native-macos.md) for authoritative
> status and next work. The Python application is now maintenance-only legacy;
> see [Legacy Python Status And Retirement](../legacy-python.md).

Evaluated on 2026-06-14 with the requirement that processing output and
user-facing functionality remain unchanged.

## Implemented

| Proposal | Decision |
|---|---|
| Fix lowercase GoPro RAW filter typo | Safe correctness fix (`*.grp` to `*.gpr`). |
| Treat missing first-run config as expected | Avoids a misleading error traceback while retaining errors for malformed configs. |
| Protect the preload tracking set | Removes the check-then-act race and avoids evicting an image while it is loading. |
| Lazy-load `psutil` | Reduces startup dependency work; export behavior is unchanged. |
| Handle exports without memory estimates | Prevents division by zero and conservatively uses one worker. |
| Remove conflicting OpenCV packages | Keeps the desktop `opencv_python` package; all three packages expose the same `cv2` namespace. |
| Simplify fixed white-balance dispatch | Removes a list allocation and makes the active algorithm explicit. |
| Add dispatch and frame/aspect tests | Covers previously untested behavior without requiring GUI automation. |

## Deferred

| Proposal | Reason |
|---|---|
| Native Swift/macOS rewrite | Historical decision superseded. The native application is now the primary product; see the current native status page. |
| Replace Matplotlib HSV conversion | Could change pixels; requires equivalence benchmarks before implementation. |
| Broaden the NumPy pin | Needs a tested Python/OpenCV compatibility matrix. |
| Split the GUI and redesign class-level settings | High churn with little immediate performance benefit. |
| Change resize/preload/export threading behavior | Requires GUI profiling and integration tests to preserve behavior. |
| Export cancellation cleanup | Valuable, but safely handling workers killed during file writes needs a designed temp-file workflow. |
| Remove dead processing methods | Low return and unnecessary compatibility risk. |

## Historical Suggested Handoff

1. Build an end-to-end import/process/export smoke test around a temporary output directory.
2. Profile representative RAFs by pipeline stage before changing algorithms.
3. Prototype Matplotlib removal only behind pixel-equivalence tests.
