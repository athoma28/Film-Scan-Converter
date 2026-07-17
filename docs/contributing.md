# Contribution Guidelines

If you're reading this, thanks for helping me take this project further beyond what I can accomplish on my own. The analog community has long been deprived of a free, intuitive, and standalone film inversion application, and your contribution will help film photography be more accessible to many more people.

## The Vision

The Film Scan Converter's primary objective is user-friendliness, in consideration of aspiring film photographers who want to spend more time shooting film than worrying about how to invert it. The core experience of using this application involves producing consistent, pleasing, workable, and exportable scans moments after importing, with little need to fiddle around with controls beforehand. This means that your contribution should not compromise on this vision, but should instead promote the ease-of-use and instant delivery of high-quality film inversions.

You are welcome to develop more technical, niche features. However, if the feature or control is not pertinent to a novice user, efforts should be made to minimize the clutter in the main GUI, and the widgets and controls for this new feature should be moved to a separate tab/window.

## How you can contribute

The primary product is the native Swift/macOS application. All new features and
new processing functionality must be implemented there. Before
starting native work, read
[Native macOS Development](development/native-macos.md). It is the authoritative
source for verified progress, limitations, and release position. Use the
[product roadmap](improvements/MacOS-Native-Roadmap.md) for ordered work.

The bounded app-path export measurement is closed, the still-preview viewport
is implemented, and packaged output contracts are covered. The current native
priority is beta feedback, direct representative-image judgment, undo/redo,
and real roll/batch workflow refinement. Stock-look learning, corpus
preparation, named-stock fitting, and ML experiments are explicitly parked
until the project owner reactivates them. Additional processing or SwiftUI
controls must close a roadmap gate or be supported by concrete user evidence.
Standalone prototypes are not product progress.

Useful contribution areas:

- Complete a task from the current roadmap.
- Add representative packaged-app or workflow-level regression coverage.
- Fix critical correctness, data-loss, or compatibility bugs in the legacy
  Python application without expanding its product surface.
- Improve processing performance only with before/after benchmarks and
  equivalence tests.

Do not add new Python UI or processing features. The legacy implementation is
retained only until the retirement gates in
[Legacy Python Application](legacy-python.md) are complete.

## Suggesting New Features

- Check that somebody else has not already suggested the same feature in [Issues](https://github.com/athoma28/Film-Scan-Converter/issues).
- Suggest new features with the [feature-request template](https://github.com/athoma28/Film-Scan-Converter/issues/new?template=feature_request.yml), including the workflow problem and why it matters.

## Reporting Bugs

- Check that the bug has not already been reported in [Issues](https://github.com/athoma28/Film-Scan-Converter/issues).
- If the bug has not yet been reported, use the [bug-report template](https://github.com/athoma28/Film-Scan-Converter/issues/new?template=bug_report.yml), including the expected behavior and steps to reproduce.
- If the bug pertains to a specific image or file, please attach a sample file to help diagnose the issue.

## Pull Requests

- Include a brief description of what changes were made, and how you tested it, if applicable.
- Include sample images especially if the change impacts the image processing pipeline.
- If the PR is fixing a bug, include the relevant issue number.
- Native processing changes to shared legacy behavior must add or update a
  compatibility test before the implementation is accepted.
- Native-only processing features without a Python equivalent must define a
  deterministic authoritative CPU contract and regression fixtures before UI or
  GPU-preview work is accepted.

## Coding Conventions

Follow the style of the code being changed rather than applying one language's
rules to the whole repository.

For the primary native Swift code:

- use two-space indentation, as in the existing Swift package;
- use normal Swift double-quoted string literals;
- keep spaces after collection elements and parameters and around operators;
- document public contracts and non-obvious invariants, without comments that
  merely restate an implementation;
- preserve the existing actor, cancellation, `Sendable`, and bounded-memory
  contracts when changing asynchronous image work.

For maintenance-only Python changes, preserve the surrounding legacy style and
keep formatting-only churn out of narrowly scoped compatibility fixes.
